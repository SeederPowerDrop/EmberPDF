#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Read-only, independent pypdf 6.10 catalog-graph checks.

Manifest: {"files": [{"id": "opaque-id", "source": "/private/input.pdf",
"source_indexes": [0, 4, 9], "outputs": [{"path": "selected.pdf", "offset": 0,
"kind": "extract"}, {"path": "merged.pdf", "offset": 1, "kind": "merge"}],
"signed_original": false}]}. Indexes are zero based. Paths are relative to the
manifest, unless absolute. Reports contain opaque IDs and error codes only.
This complements, rather than substitutes for, qpdf/text/raster validation.
Existing unreachable-MCR producer defects are warnings only when the selected
page, MCID and exact stream bytes match; newly broken output references fail.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import logging
import os
from pathlib import Path
import re
import sys
import tempfile

from pypdf import PdfReader
from pypdf.generic import ArrayObject, DictionaryObject, IndirectObject, NameObject, NullObject

MAX_FILES = 30
MAX_NODES = 500_000
MAX_DEPTH = 256
MAX_ATTACHMENT_BYTES = 256 * 1024 * 1024
MAX_ATTACHMENTS = 1000


class InvalidGraph(ValueError):
    pass


def resolve(value):
    return value.get_object() if isinstance(value, IndirectObject) else value


def identity(value):
    if isinstance(value, IndirectObject):
        return (id(value.pdf), value.idnum, value.generation)
    reference = getattr(value, "indirect_reference", None)
    if isinstance(reference, IndirectObject):
        return identity(reference)
    return ("direct", id(value))


def is_null(value):
    return value is None or isinstance(resolve(value), NullObject)


def sequence(value):
    value = resolve(value)
    return list(value) if isinstance(value, (list, ArrayObject)) else [value]


def digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def byte_string(value):
    value = resolve(value)
    if isinstance(value, bytes):
        return value
    try:
        return value.original_bytes
    except (AttributeError, UnicodeError):
        return str(value).encode("utf-8")


def destination_name(value):
    value = resolve(value)
    return str(value)[1:].encode("utf-8") if isinstance(value, NameObject) else byte_string(value)


class Budget:
    def __init__(self, maximum=MAX_NODES):
        self.maximum = maximum
        self.visits = 0

    def step(self, depth=0):
        self.visits += 1
        if self.visits > self.maximum or depth > MAX_DEPTH:
            raise InvalidGraph("graph_budget_exceeded")


def tree_pairs(root, field, budget):
    result = []
    seen = set()

    def visit(raw, depth):
        budget.step(depth)
        key = identity(raw)
        if key in seen:
            raise InvalidGraph("tree_cycle_or_shared_node")
        seen.add(key)
        node = resolve(raw)
        if not isinstance(node, DictionaryObject):
            raise InvalidGraph("invalid_tree_node")
        values = resolve(node.get(field, []))
        if not isinstance(values, (list, ArrayObject)) or len(values) % 2:
            raise InvalidGraph("invalid_tree_pairs")
        for offset in range(0, len(values), 2):
            budget.step(depth)
            result.append((values[offset], values[offset + 1]))
        kids = resolve(node.get("/Kids", []))
        if not isinstance(kids, (list, ArrayObject)):
            raise InvalidGraph("invalid_tree_kids")
        for child in kids:
            visit(child, depth + 1)

    if not is_null(root):
        visit(root, 0)
    return result


class Audit:
    def __init__(self, reader, maximum=MAX_NODES):
        self.reader = reader
        self.root = reader.root_object
        self.budget = Budget(maximum)
        self.errors = Counter()
        self.pages = list(reader.pages)
        self.page_ids = {identity(page): index for index, page in enumerate(self.pages)}
        self.annotations = {}  # object identity -> owning page identity
        self.resources = set()
        self.form_streams = set()
        self.parent_uses = {}  # key -> (owner identity, is MCID array)
        self.parent_aliases = {}  # producer-shared Form keys retain all owners
        self.owner_streams = {}
        self.unreachable_mcrs = Counter()
        self.shared_form_keys = Counter()
        self.page_ocgs = [set() for _ in self.pages]
        self.ocg_signatures = {}
        self.elements = set()
        self.content_links = []
        self.objr_links = []
        self.tag_count = 0
        self.metadata_tags = 0
        self.parent_slots = 0

    def issue(self, code):
        self.errors[code] += 1

    def require_page(self, value):
        if identity(value) not in self.page_ids:
            self.issue("dangling_page_reference")
            return None
        return identity(value)

    def parent_use(self, dictionary, array):
        field = "/StructParents" if array else "/StructParent"
        if field not in dictionary:
            return
        key = resolve(dictionary.get(field))
        if type(key) is bool or not isinstance(key, int) or key < 0:
            self.issue("invalid_struct_parent_key")
            return
        owner = identity(dictionary)
        if hasattr(dictionary, "get_data"):
            self.owner_streams[owner] = hashlib.sha256(dictionary.get_data()).hexdigest()
        previous = self.parent_uses.get(int(key))
        if previous is not None and previous != (owner, array):
            if owner not in self.parent_aliases.get(int(key), set()):
                if owner in self.owner_streams and previous[0] in self.owner_streams:
                    pair = tuple(sorted((self.owner_streams[owner], self.owner_streams[previous[0]])))
                    self.shared_form_keys[pair] += 1
                    self.issue("shared_form_struct_parent_key")
                else:
                    self.issue("duplicate_struct_parent_key")
        else:
            self.parent_uses[int(key)] = (owner, array)
        self.parent_aliases.setdefault(int(key), set()).add(owner)

    def oc_reference(self, raw, page_index, seen=None):
        if is_null(raw):
            return
        self.budget.step()
        seen = set() if seen is None else seen
        key = identity(raw)
        if key in seen:
            return
        seen.add(key)
        node = resolve(raw)
        if not isinstance(node, DictionaryObject):
            return
        kind = node.get("/Type")
        if kind == "/OCG":
            self.page_ocgs[page_index].add(key)
            self.ocg_signatures[key] = ocg_fingerprint(node)
        elif kind == "/OCMD":
            for value in sequence(node.get("/OCGs", [])):
                self.oc_reference(value, page_index, seen)
            def expression(raw_expression, depth):
                self.budget.step(depth)
                expression_node = resolve(raw_expression)
                if isinstance(expression_node, (list, ArrayObject)):
                    for member in expression_node:
                        expression(member, depth + 1)
                elif isinstance(expression_node, DictionaryObject):
                    self.oc_reference(raw_expression, page_index, seen)
            expression(node.get("/VE", []), 0)

    def collect_page_objects(self):
        for index, page in enumerate(self.pages):
            self.parent_use(page, True)
            for annotation in sequence(page.get("/Annots", [])):
                self.budget.step()
                obj = resolve(annotation)
                if not isinstance(obj, DictionaryObject):
                    self.issue("invalid_page_annotation")
                    continue
                self.annotations[identity(annotation)] = identity(page)
                self.parent_use(obj, False)
                if "/P" in obj and identity(obj.get("/P")) != identity(page):
                    self.issue("annotation_page_mismatch")
                self.oc_reference(obj.get("/OC"), index)
            visited = set()
            def resources(raw, depth):
                self.budget.step(depth)
                node = resolve(raw)
                if not isinstance(node, DictionaryObject):
                    return
                key = identity(raw)
                if key in visited:
                    return
                visited.add(key)
                properties = resolve(node.get("/Properties", {}))
                if isinstance(properties, DictionaryObject):
                    for value in properties.values():
                        self.oc_reference(value, index)
                xobjects = resolve(node.get("/XObject", {}))
                if isinstance(xobjects, DictionaryObject):
                    for value in xobjects.values():
                        self.budget.step(depth)
                        obj = resolve(value)
                        if not isinstance(obj, DictionaryObject):
                            self.issue("invalid_resource_object")
                            continue
                        self.resources.add(identity(value))
                        self.oc_reference(obj.get("/OC"), index)
                        if obj.get("/Subtype") == "/Form":
                            self.form_streams.add(identity(value))
                            self.parent_use(obj, True)
                            resources(obj.get("/Resources", {}), depth + 1)
            resources(page.get("/Resources", {}), 0)

    def tags(self):
        raw_root = self.root.get("/StructTreeRoot")
        if is_null(raw_root):
            if self.parent_uses:
                self.issue("struct_parent_without_tree")
            return
        root = resolve(raw_root)
        if not isinstance(root, DictionaryObject):
            raise InvalidGraph("invalid_struct_tree_root")
        active, finished = set(), set()
        root_id = identity(raw_root)

        def children(raw, inherited_page, parent, depth):
            self.budget.step(depth)
            node = resolve(raw)
            if is_null(node):
                return
            if isinstance(node, (list, ArrayObject)):
                for value in node:
                    children(value, inherited_page, parent, depth + 1)
                return
            if isinstance(node, int):
                if inherited_page is None or node < 0:
                    self.issue("mcid_without_page_or_negative")
                else:
                    self.content_links.append((parent, inherited_page, int(node)))
                return
            if not isinstance(node, DictionaryObject):
                self.issue("invalid_struct_kid")
                return
            kind = node.get("/Type")
            page = inherited_page
            if "/Pg" in node:
                page = self.require_page(node.get("/Pg"))
            if kind == "/MCR" or "/MCID" in node:
                mcid = resolve(node.get("/MCID"))
                owner = identity(node.get("/Stm")) if "/Stm" in node else page
                if "/Stm" in node:
                    stream = resolve(node.get("/Stm"))
                    if hasattr(stream, "get_data"):
                        self.parent_use(stream, True)
                    if owner not in self.form_streams:
                        self.issue("mcr_stream_not_page_resource")
                        if hasattr(stream, "get_data") and page is not None and isinstance(mcid, int):
                            self.unreachable_mcrs[(self.page_ids[page], int(mcid), hashlib.sha256(stream.get_data()).hexdigest())] += 1
                if not isinstance(mcid, int) or mcid < 0 or owner is None:
                    self.issue("invalid_mcr")
                else:
                    self.content_links.append((parent, owner, int(mcid)))
                return
            if kind == "/OBJR":
                obj = identity(node.get("/Obj"))
                if obj not in self.annotations and obj not in self.resources:
                    self.issue("objr_object_not_page_object")
                if obj in self.annotations and page is not None and self.annotations[obj] != page:
                    self.issue("objr_annotation_page_mismatch")
                self.objr_links.append((parent, obj))
                return
            key = identity(raw)
            if key in active:
                raise InvalidGraph("struct_tree_cycle")
            if key in finished:
                self.issue("struct_element_has_multiple_parents")
                return
            active.add(key)
            self.elements.add(key)
            self.tag_count += 1
            if "/S" not in node:
                self.issue("struct_element_missing_role")
            if identity(node.get("/P")) != parent:
                self.issue("struct_parent_pointer_mismatch")
            if "/Metadata" in node or "/Info" in node:
                self.metadata_tags += 1
            if "/K" in node:
                children(node.get("/K"), page, key, depth + 1)
            active.remove(key)
            finished.add(key)

        children(root.get("/K", []), None, root_id, 0)
        pairs = tree_pairs(root.get("/ParentTree"), "/Nums", self.budget)
        parents = {}
        last = -1
        for key, value in pairs:
            key = resolve(key)
            if not isinstance(key, int) or key < 0 or key in parents or key <= last:
                self.issue("invalid_parent_tree_keys")
                continue
            parents[int(key)] = resolve(value)
            last = int(key)
        for key, (owner, array) in self.parent_uses.items():
            value = parents.get(key)
            if value is None:
                self.issue("missing_parent_tree_entry")
                continue
            if array:
                if not isinstance(value, (list, ArrayObject)):
                    self.issue("parent_tree_mcid_value_not_array")
                    continue
                for target in value:
                    if not is_null(target) and identity(target) not in self.elements:
                        self.issue("parent_tree_target_not_struct_element")
                    if not is_null(target):
                        self.parent_slots += 1
            elif identity(value) not in self.elements:
                self.issue("parent_tree_objr_target_not_struct_element")
        for key in parents.keys() - self.parent_uses.keys():
            self.issue("orphan_parent_tree_key")
        uses_by_owner = {owner: parents.get(key) for key, owners in self.parent_aliases.items() for owner in owners}
        for element, owner, mcid in self.content_links:
            slots = uses_by_owner.get(owner)
            if not isinstance(slots, (list, ArrayObject)) or mcid >= len(slots) or identity(slots[mcid]) != element:
                self.issue("mcid_parent_slot_mismatch")
        for element, obj in self.objr_links:
            if identity(uses_by_owner.get(obj)) != element:
                self.issue("objr_parent_target_mismatch")
        if "/ParentTreeNextKey" in root and parents:
            next_key = resolve(root.get("/ParentTreeNextKey"))
            if not isinstance(next_key, int) or next_key <= max(parents):
                self.issue("invalid_parent_tree_next_key")

    def destinations(self):
        named = {}
        names = resolve(self.root.get("/Names", {}))
        if isinstance(names, DictionaryObject):
            for name, value in tree_pairs(names.get("/Dests"), "/Names", self.budget):
                key = destination_name(name)
                if key in named:
                    self.issue("duplicate_named_destination")
                named[key] = value
        legacy = resolve(self.root.get("/Dests", {}))
        if isinstance(legacy, DictionaryObject):
            named.update((str(key).lstrip("/").encode("utf-8"), value) for key, value in legacy.items())

        def destination(raw, active=None):
            self.budget.step()
            active = set() if active is None else active
            node = resolve(raw)
            if isinstance(node, DictionaryObject):
                destination(node.get("/D"), active)
            elif isinstance(node, (list, ArrayObject)):
                if not node:
                    self.issue("empty_destination")
                else:
                    self.require_page(node[0])
            elif not is_null(node):
                key = destination_name(node)
                if key in active or key not in named:
                    self.issue("unknown_named_destination")
                else:
                    destination(named[key], active | {key})
            else:
                self.issue("invalid_destination")

        for value in named.values():
            destination(value)
        visited = set()
        def walk(raw, depth):
            self.budget.step(depth)
            key = identity(raw)
            if key in visited:
                return
            node = resolve(raw)
            if isinstance(node, DictionaryObject):
                visited.add(key)
                if node.get("/S") == "/GoTo":
                    destination(node.get("/D"))
                if "/Dest" in node:
                    destination(node.get("/Dest"))
                if "/OpenAction" in node:
                    action = resolve(node.get("/OpenAction"))
                    if isinstance(action, (list, ArrayObject)) or not isinstance(action, DictionaryObject):
                        destination(action)
                # Traverses only navigation/annotation/form action graphs, never
                # font programs, page parent trees, or embedded payload streams.
                for field in ("/Outlines", "/First", "/Next", "/A", "/AA", "/OpenAction", "/Kids", "/Fields", "/AcroForm"):
                    if field in node:
                        walk(node.get(field), depth + 1)
                if node.get("/Type") is None and not any(k in node for k in ("/S", "/Subtype", "/FT")):
                    for value in node.values():
                        if isinstance(resolve(value), (DictionaryObject, list, ArrayObject)):
                            walk(value, depth + 1)
            elif isinstance(node, (list, ArrayObject)):
                for value in node:
                    walk(value, depth + 1)
        walk(self.root, 0)
        for page in self.pages:
            for annotation in sequence(page.get("/Annots", [])):
                walk(annotation, 0)
            if "/AA" in page:
                walk(page.get("/AA"), 0)

    def layers(self):
        if is_null(self.root.get("/OCProperties")):
            if any(self.page_ocgs):
                self.issue("painting_ocg_missing_from_catalog")
            return
        properties = resolve(self.root.get("/OCProperties", {}))
        if not isinstance(properties, DictionaryObject):
            self.issue("invalid_ocproperties")
            return
        groups = sequence(properties.get("/OCGs", []))
        ids = set()
        for group in groups:
            node = resolve(group)
            if not isinstance(node, DictionaryObject) or node.get("/Type") != "/OCG":
                self.issue("invalid_catalog_ocg")
            ids.add(identity(group))
        if len(ids) != len(groups):
            self.issue("duplicate_catalog_ocg")
        for used in self.page_ocgs:
            if not used <= ids:
                self.issue("painting_ocg_missing_from_catalog")
        def group_refs(raw, depth):
            self.budget.step(depth)
            node = resolve(raw)
            if isinstance(node, (list, ArrayObject)):
                for value in node:
                    group_refs(value, depth + 1)
            elif isinstance(node, DictionaryObject) and node.get("/Type") == "/OCG" and identity(raw) not in ids:
                self.issue("layer_config_unknown_ocg")
        for config in [properties.get("/D", {})] + sequence(properties.get("/Configs", [])):
            node = resolve(config)
            if not isinstance(node, DictionaryObject):
                self.issue("invalid_layer_config")
                continue
            for field in ("/ON", "/OFF", "/Order", "/RBGroups", "/Locked"):
                group_refs(node.get(field, []), 0)
            for application in sequence(node.get("/AS", [])):
                obj = resolve(application)
                if isinstance(obj, DictionaryObject):
                    group_refs(obj.get("/OCGs", []), 0)

    def unsigned(self):
        visited = set()
        def walk(raw, depth):
            self.budget.step(depth)
            node = resolve(raw)
            key = identity(raw)
            if isinstance(node, (DictionaryObject, list, ArrayObject)):
                if key in visited:
                    return
                visited.add(key)
            if isinstance(node, DictionaryObject):
                if "/ByteRange" in node or node.get("/Type") == "/Sig" or (node.get("/FT") == "/Sig" and not is_null(node.get("/V"))):
                    self.issue("assembled_output_retains_live_signature")
                for value in node.values():
                    walk(value, depth + 1)
            elif isinstance(node, (list, ArrayObject)):
                for value in node:
                    walk(value, depth + 1)
        walk(self.root, 0)

    def run(self):
        self.collect_page_objects()
        self.tags()
        self.destinations()
        self.layers()
        return self


def ocg_fingerprint(node):
    def plain(raw, depth=0):
        if depth > 16:
            raise InvalidGraph("ocg_metadata_budget_exceeded")
        value = resolve(raw)
        if isinstance(value, DictionaryObject):
            return {str(k): plain(v, depth + 1) for k, v in sorted(value.items()) if k not in ("/Type",)}
        if isinstance(value, (list, ArrayObject)):
            return [plain(v, depth + 1) for v in value]
        return str(value)
    return hashlib.sha256(json.dumps(plain(node), sort_keys=True).encode()).hexdigest()


def layer_visibility(reader, keys):
    properties = resolve(reader.root_object.get("/OCProperties", {}))
    config = resolve(properties.get("/D", {})) if isinstance(properties, DictionaryObject) else {}
    if not isinstance(config, DictionaryObject):
        return {key: True for key in keys}
    base = config.get("/BaseState", "/ON") != "/OFF"
    on = {identity(value) for value in sequence(config.get("/ON", []))}
    off = {identity(value) for value in sequence(config.get("/OFF", []))}
    return {key: False if key in off else True if key in on else base for key in keys}


def named_destination_pages(reader, budget):
    names = resolve(reader.root_object.get("/Names", {}))
    entries = tree_pairs(names.get("/Dests"), "/Names", budget) if isinstance(names, DictionaryObject) else []
    legacy = resolve(reader.root_object.get("/Dests", {}))
    if isinstance(legacy, DictionaryObject):
        entries += [(str(key).lstrip("/").encode("utf-8"), value) for key, value in legacy.items()]
    values = {destination_name(name): value for name, value in entries}
    pages = {identity(page): index for index, page in enumerate(reader.pages)}
    def target(raw, active):
        budget.step()
        node = resolve(raw)
        if isinstance(node, DictionaryObject):
            return target(node.get("/D"), active)
        if isinstance(node, (list, ArrayObject)):
            return pages.get(identity(node[0])) if node else None
        if not is_null(node):
            key = destination_name(node)
            if key in values and key not in active:
                return target(values[key], active | {key})
        return None
    return {name: target(value, {name}) for name, value in values.items()}


def selected_tag_graph(reader, indexes, assets):
    """Mirror page selection, without repairing a producer's broken links.

    In particular a ParentTree entry for an excluded page is not an expected
    retained slot merely because a selected Form reused the same parent key.
    """
    budget = assets.budget
    selected = {identity(reader.pages[index]): index for index in indexes}
    root = resolve(reader.root_object.get("/StructTreeRoot", {}))
    if not isinstance(root, DictionaryObject):
        return set()
    parent_tree = {int(resolve(key)): resolve(value) for key, value in tree_pairs(root.get("/ParentTree"), "/Nums", budget)}
    retained, active = set(), set()
    page_parent_values = []
    for index in indexes:
        page = reader.pages[index]
        key = resolve(page.get("/StructParents"))
        if isinstance(key, int):
            value = parent_tree.get(int(key))
            if isinstance(value, (list, ArrayObject)):
                page_parent_values.append((identity(page), value))

    def visit(raw, page, owner, depth):
        budget.step(depth)
        node = resolve(raw)
        if is_null(node):
            return False
        if isinstance(node, (list, ArrayObject)):
            kept = False
            for value in node:
                kept = visit(value, page, owner, depth + 1) or kept
            return kept
        if isinstance(node, int):
            if page is not None:
                return page in selected
            return any(0 <= node < len(values) and identity(values[node]) == owner for _, values in page_parent_values)
        if not isinstance(node, DictionaryObject):
            return False
        if "/Pg" in node:
            page = identity(node.get("/Pg"))
        if node.get("/Type") == "/OBJR" or "/Obj" in node:
            return identity(node.get("/Obj")) in assets.annotations or identity(node.get("/Obj")) in assets.resources
        if node.get("/Type") == "/MCR" or "/MCID" in node:
            mcid = resolve(node.get("/MCID"))
            if page is None and isinstance(mcid, int):
                candidates = [candidate for candidate, values in page_parent_values
                              if 0 <= mcid < len(values) and identity(values[mcid]) == owner]
                page = candidates[0] if len(candidates) == 1 else None
            keep = page in selected
            if keep and "/Stm" in node:
                stream = resolve(node.get("/Stm"))
                if hasattr(stream, "get_data"):
                    assets.parent_use(stream, True)
                    if identity(stream) not in assets.form_streams and isinstance(mcid, int):
                        assets.unreachable_mcrs[(selected[page], int(mcid), hashlib.sha256(stream.get_data()).hexdigest())] += 1
            return keep
        key = identity(raw)
        if key in active:
            raise InvalidGraph("struct_tree_cycle")
        active.add(key)
        children = resolve(node.get("/K"))
        has_content = visit(node.get("/K"), page, key, depth + 1) if "/K" in node else False
        empty = is_null(children) or isinstance(children, (list, ArrayObject)) and not children
        keep = has_content or empty and (page is None or page in selected)
        if keep:
            retained.add(key)
        active.remove(key)
        return keep
    visit(root.get("/K", []), None, None, 0)
    return retained


def selected_parent_slots(reader, uses, budget, retained=None):
    root = resolve(reader.root_object.get("/StructTreeRoot", {}))
    if not isinstance(root, DictionaryObject):
        return 0
    tree = dict((int(resolve(key)), resolve(value)) for key, value in tree_pairs(root.get("/ParentTree"), "/Nums", budget))
    return sum(sum(not is_null(value) and (retained is None or identity(value) in retained) for value in tree.get(key, []))
               for key, (_, array) in uses.items() if array and isinstance(tree.get(key), (list, ArrayObject)))


def unpaged_metadata_tags(reader, budget):
    """Metadata-only roots must not pass merely because an empty tree remains."""
    root = resolve(reader.root_object.get("/StructTreeRoot", {}))
    result, seen = Counter(), set()
    def fingerprint(raw, depth):
        budget.step(depth)
        node = resolve(raw)
        if hasattr(node, "get_data"):
            data = node.get_data()
            if len(data) > 16 * 1024 * 1024:
                raise InvalidGraph("metadata_payload_budget_exceeded")
            return ["stream", hashlib.sha256(data).hexdigest()]
        if isinstance(node, DictionaryObject):
            return {str(key): fingerprint(value, depth + 1) for key, value in sorted(node.items()) if key not in ("/P", "/Pg")}
        if isinstance(node, (list, ArrayObject)):
            return [fingerprint(value, depth + 1) for value in node]
        return str(node)
    def visit(raw, inherited_page, depth):
        budget.step(depth)
        node = resolve(raw)
        if isinstance(node, (list, ArrayObject)):
            for value in node:
                visit(value, inherited_page, depth + 1)
        elif isinstance(node, DictionaryObject):
            key = identity(raw)
            if key in seen:
                return
            seen.add(key)
            paged = inherited_page or "/Pg" in node
            kids = resolve(node.get("/K"))
            empty_kids = is_null(kids) or isinstance(kids, (list, ArrayObject)) and not kids
            if not paged and empty_kids and any(field in node for field in ("/Info", "/Metadata")):
                payload = {field: fingerprint(node.get(field), 0) for field in ("/Info", "/Metadata") if field in node}
                result[hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()] += 1
            if "/K" in node:
                visit(node.get("/K"), paged, depth + 1)
    if isinstance(root, DictionaryObject):
        visit(root.get("/K", []), False, 0)
    return result


def attachments(reader, budget):
    specs = []
    root = reader.root_object
    names = resolve(root.get("/Names", {}))
    if isinstance(names, DictionaryObject):
        specs.extend((byte_string(name), value) for name, value in tree_pairs(names.get("/EmbeddedFiles"), "/Names", budget))
    specs.extend((b"", value) for value in sequence(root.get("/AF", [])))
    result, seen = [], set()
    for name, raw in specs:
        budget.step()
        if identity(raw) in seen:
            continue
        seen.add(identity(raw))
        if len(seen) > MAX_ATTACHMENTS:
            raise InvalidGraph("attachment_count_budget_exceeded")
        spec = resolve(raw)
        if not isinstance(spec, DictionaryObject):
            raise InvalidGraph("invalid_attachment_filespec")
        embedded = resolve(spec.get("/EF", {}))
        if not isinstance(embedded, DictionaryObject):
            raise InvalidGraph("invalid_attachment_ef")
        payloads = set()
        for key in ("/F", "/UF", "/DOS", "/Mac", "/Unix"):
            raw_stream = embedded.get(key)
            if is_null(raw_stream) or identity(raw_stream) in payloads:
                continue
            payloads.add(identity(raw_stream))
            stream = resolve(raw_stream)
            if not hasattr(stream, "get_data"):
                raise InvalidGraph("invalid_attachment_stream")
            params = resolve(stream.get("/Params", {}))
            if isinstance(params, DictionaryObject) and int(resolve(params.get("/Size", 0))) > MAX_ATTACHMENT_BYTES:
                raise InvalidGraph("attachment_payload_budget_exceeded")
            data = stream.get_data()
            if len(data) > MAX_ATTACHMENT_BYTES:
                raise InvalidGraph("attachment_payload_budget_exceeded")
            result.append((name or byte_string(spec.get("/UF", spec.get("/F", ""))), hashlib.sha256(data).hexdigest()))
    return result


def read_manifest(path):
    raw = json.loads(path.read_text(encoding="utf-8"))
    rows = raw if isinstance(raw, list) else raw.get("files", [])
    if not 1 <= len(rows) <= MAX_FILES:
        raise ValueError("manifest_requires_1_to_30_explicit_files")
    ids = [row.get("id", "") for row in rows]
    if len(set(ids)) != len(ids) or any(not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", value) for value in ids):
        raise ValueError("manifest_ids_must_be_unique_safe_names")
    def file(value):
        result = Path(value)
        return str((result if result.is_absolute() else path.parent / result).resolve(strict=True))
    for row in rows:
        row["source"] = file(row.get("source", row.get("source_path", row.get("path"))))
        indexes = row.get("source_indexes", [])
        if not 1 <= len(indexes) <= 3 or len(set(indexes)) != len(indexes) or any(type(i) is not int or i < 0 for i in indexes):
            raise ValueError("manifest_requires_1_to_3_unique_source_indexes")
        outputs = row.get("outputs", [])
        if not 1 <= len(outputs) <= 2:
            raise ValueError("manifest_requires_1_to_2_outputs")
        for output in outputs:
            output["path"] = file(output["path"])
            if type(output.get("offset")) is not int or output["offset"] not in (0, 1):
                raise ValueError("manifest_output_offset_must_be_zero_or_one")
            if output.get("kind") not in ("extract", "merge"):
                raise ValueError("manifest_output_kind_invalid")
            if output["offset"] != (1 if output["kind"] == "merge" else 0):
                raise ValueError("manifest_output_kind_offset_mismatch")
            if Path(output["path"]).samefile(row["source"]):
                raise ValueError("output_must_not_alias_original_source")
    return rows


def verify_row(row, maximum=MAX_NODES):
    source_path = Path(row["source"])
    before = (source_path.stat().st_size, source_path.stat().st_mtime_ns, digest(source_path))
    result = {"id": row["id"], "status": "passed", "source_sha256": before[2], "outputs": []}
    try:
        source = PdfReader(source_path)
        indexes = row["source_indexes"]
        if max(indexes) >= len(source.pages):
            raise InvalidGraph("source_index_out_of_bounds")
        source_assets = attachments(source, Budget(maximum))
        source_pages = Audit(source, maximum)
        # Collect only selected page assets. Avoid walking every page's streams
        # or validating unrelated original tags in a multi-thousand-page source.
        source_pages.pages = [source.pages[index] for index in indexes]
        source_pages.page_ocgs = [set() for _ in indexes]
        source_pages.collect_page_objects()
        source_tagged = not is_null(source.root_object.get("/StructTreeRoot"))
        source_labels = source.page_labels if "/PageLabels" in source.root_object else None
        retained_elements = selected_tag_graph(source, indexes, source_pages)
        source_slots = selected_parent_slots(source, source_pages.parent_uses, source_pages.budget, retained_elements)
        source_metadata_tags = unpaged_metadata_tags(source, source_pages.budget)
        source_visibility = layer_visibility(source, source_pages.ocg_signatures)
        source_destinations = named_destination_pages(source, source_pages.budget)
        for output in row["outputs"]:
            checked = {"kind": output["kind"], "offset": output["offset"], "status": "passed", "errors": {}, "checks": {}}
            result["outputs"].append(checked)
            try:
                reader = PdfReader(output["path"])
                audit = Audit(reader, maximum).run()
                offset = output["offset"]
                if len(reader.pages) != len(indexes) + offset:
                    audit.issue("output_page_count_mismatch")
                labels = reader.page_labels
                for position, index in enumerate(indexes):
                    out_index = position + offset
                    expected_label = source_labels[index] if source_labels is not None else str(out_index + 1)
                    if out_index >= len(labels) or labels[out_index] != expected_label:
                        audit.issue("page_label_mismatch")
                    if out_index < len(audit.page_ocgs):
                        output_visibility = layer_visibility(reader, audit.ocg_signatures)
                        expected = Counter((source_pages.ocg_signatures[key], source_visibility[key]) for key in source_pages.page_ocgs[position])
                        actual = Counter((audit.ocg_signatures[key], output_visibility[key]) for key in audit.page_ocgs[out_index])
                        if expected != actual:
                            audit.issue("selected_page_ocg_semantics_mismatch")
                if source_tagged and is_null(reader.root_object.get("/StructTreeRoot")):
                    audit.issue("source_structure_tree_missing")
                if audit.parent_slots < source_slots:
                    audit.issue("selected_source_parent_slots_missing")
                if source_metadata_tags - unpaged_metadata_tags(reader, audit.budget):
                    audit.issue("source_metadata_only_tags_missing")
                output_destinations = named_destination_pages(reader, audit.budget)
                selected_map = {source_index: position + offset for position, source_index in enumerate(indexes)}
                for name, source_index in source_destinations.items():
                    if source_index in selected_map and output_destinations.get(name) != selected_map[source_index]:
                        audit.issue("selected_named_destination_missing_or_changed")
                output_assets = attachments(reader, audit.budget)
                expected_assets = Counter(value for _, value in source_assets)
                actual_assets = Counter(value for _, value in output_assets)
                if expected_assets - actual_assets:
                    audit.issue("source_attachment_payload_missing")
                if row.get("signed_original", row["id"] == "pdf-026"):
                    if not any(name.startswith(b"Signed-original-") and value == before[2] for name, value in output_assets):
                        audit.issue("signed_original_exact_attachment_missing")
                    audit.unsigned()
                # A producer's existing unreachable MCR is reported explicitly
                # only when page, MCID and exact stream bytes still match. A
                # new/unrelated broken reference remains an output failure.
                expected_unreachable = Counter((indexes.index(page) + offset, mcid, sha)
                                               for (page, mcid, sha), count in source_pages.unreachable_mcrs.items()
                                               for _ in range(count))
                known_mcrs = sum((audit.unreachable_mcrs & expected_unreachable).values())
                known_shared = sum((audit.shared_form_keys & source_pages.shared_form_keys).values())
                warnings = {}
                for code, count in (("mcr_stream_not_page_resource", known_mcrs), ("shared_form_struct_parent_key", known_shared)):
                    if count:
                        audit.errors[code] -= count
                        warnings["preexisting_source_" + code] = count
                checked["errors"] = {key: count for key, count in sorted(audit.errors.items()) if count}
                checked["source_warnings"] = warnings
                checked["checks"] = {"pages": len(reader.pages), "struct_elements": audit.tag_count,
                                     "metadata_struct_elements": audit.metadata_tags, "mcid_links": len(audit.content_links),
                                     "objr_links": len(audit.objr_links), "parent_keys": len(audit.parent_uses),
                                     "parent_slots": audit.parent_slots, "expected_source_parent_slots": source_slots,
                                     "attachment_payloads": len(output_assets), "painting_ocgs": len(audit.ocg_signatures),
                                     "graph_visits": audit.budget.visits}
                if checked["errors"]:
                    checked["status"] = "failed"
            except InvalidGraph as error:
                checked["status"] = "failed"
                checked["errors"] = {str(error): 1}
            except Exception:
                checked["status"] = "failed"
                checked["errors"] = {"output_parser_or_structure_error": 1}
    except InvalidGraph as error:
        result["status"] = "failed"
        result["source_error"] = str(error)
    except Exception:
        result["status"] = "failed"
        result["source_error"] = "source_parser_or_structure_error"
    finally:
        after = (source_path.stat().st_size, source_path.stat().st_mtime_ns, digest(source_path))
        result["source_unchanged"] = before == after
        if before != after:
            result["status"] = "failed"
            result["source_error"] = "source_changed_during_validation"
    if any(output["status"] != "passed" for output in result["outputs"]):
        result["status"] = "failed"
    return result


def write_report(path, report, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    for row in rows:
        for value in [row["source"]] + [output["path"] for output in row["outputs"]]:
            if path.resolve() == Path(value).resolve() or (path.exists() and path.samefile(value)):
                raise ValueError("report_must_not_alias_an_input")
    descriptor, temporary = tempfile.mkstemp(prefix=".catalog-report-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(report, stream, indent=2)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--max-nodes", type=int, default=MAX_NODES)
    args = parser.parse_args(argv)
    # Parser diagnostics may contain private filenames or document strings.
    logging.getLogger("pypdf").setLevel(logging.CRITICAL)
    try:
        if not 1 <= args.max_nodes <= MAX_NODES:
            raise ValueError("invalid_graph_budget")
        rows = read_manifest(args.manifest)
        results = [verify_row(row, args.max_nodes) for row in rows]
        report = {"schema": 1, "validator": "pypdf_catalog_graph", "pypdf_version": __import__("pypdf").__version__,
                  "documents": len(results), "passed": sum(row["status"] == "passed" for row in results),
                  "failed": sum(row["status"] != "passed" for row in results),
                  "source_warning_documents": sum(any(output.get("source_warnings") for output in row["outputs"]) for row in results),
                  "source_warning_outputs": sum(bool(output.get("source_warnings")) for row in results for output in row["outputs"]),
                  "results": results}
        write_report(args.report, report, rows)
        print(json.dumps({key: report[key] for key in ("documents", "passed", "failed")}))
        return 1 if report["failed"] else 0
    except Exception as error:
        code = str(error) if isinstance(error, ValueError) and re.fullmatch(r"[a-z0-9_]+", str(error)) else "validator_setup_error"
        print(json.dumps({"status": "failed", "error": code}))
        return 2


if __name__ == "__main__":
    sys.exit(main())
