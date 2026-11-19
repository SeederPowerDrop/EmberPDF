#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Independent checks of explicitly selected PDF outputs. Never edits an input.

qpdf checks serialization, Poppler extracts text and renders pages, and pypdf
checks canonical form values. Missing tools fail instead of reporting a pass.
Private corpus manifests stay local; reports use caller supplied opaque ids.
"""
from __future__ import annotations

import argparse
import difflib
import gc
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unicodedata


MAX_FILES = 30
MAX_TEXT_BYTES = 16 * 1024 * 1024


def normalized(text: str) -> str:
    return " ".join(unicodedata.normalize("NFKC", text).split())


def sequence_agreement(a: str, b: str) -> dict:
    # A bag-of-words score cannot detect swapped paragraphs. Bound the sequence
    # comparison; explicitly report truncation rather than treating it as exact.
    left, right = normalized(a).split(), normalized(b).split()
    truncated = max(len(left), len(right)) > 3000
    left, right = left[:3000], right[:3000]
    if left == right:
        return {"score": 1.0, "truncated": truncated,
                "compared_words": [len(left), len(right)]}
    matches = sum(block.size for block in difflib.SequenceMatcher(
        None, left, right, autojunk=False).get_matching_blocks())
    return {"score": matches / max(len(left), len(right), 1),
            "truncated": truncated, "compared_words": [len(left), len(right)]}


def run(command: list[str], timeout: float, accepted=(0,)) -> dict:
    began = time.monotonic()
    try:
        result = subprocess.run(command, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=timeout, check=False)
    except subprocess.TimeoutExpired as error:
        raise ValueError("external_tool_timeout") from error
    if result.returncode not in accepted:
        # Tool stderr can contain private paths or extracted text. Keep it out
        # of the portable report; use the exit status and a bounded local log.
        raise ValueError(f"external_tool_exit_{result.returncode}")
    return {"code": result.returncode, "seconds": round(time.monotonic() - began, 4),
            "stdout": result.stdout, "stderr": result.stderr}


def resolve_tool(value: str) -> str:
    tool = shutil.which(value)
    if not tool:
        raise ValueError(f"required_tool_missing:{Path(value).name}")
    return tool


def read_manifest(path: Path) -> tuple[list[dict], bool]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    source_only = isinstance(raw, list)
    items = raw if source_only else raw.get("files", [])
    if not 1 <= len(items) <= MAX_FILES:
        raise ValueError("manifest_requires_1_to_30_explicit_files")
    ids = [item.get("id", "") for item in items]
    if len(set(ids)) != len(ids) or any(not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", i) for i in ids):
        raise ValueError("manifest_ids_must_be_unique_safe_names")
    for item in items:
        file = Path(item["path"])
        if not file.is_absolute():
            file = path.parent / file
        item["path"] = str(file.resolve(strict=True))
        if item.get("reference"):
            reference = Path(item["reference"])
            if not reference.is_absolute():
                reference = path.parent / reference
            item["reference"] = str(reference.resolve(strict=True))
        pages = item.get("pages", [1])
        if not 1 <= len(pages) <= 3 or any(type(p) is not int or p < 1 for p in pages):
            raise ValueError("sample_requires_1_to_3_positive_page_numbers")
    return items, source_only


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def prepare_output(directory: Path, items: list[dict]) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    report = directory / "report.json"
    for item in items:
        for value in (item["path"], item.get("reference")):
            if value and (report.resolve() == Path(value).resolve()
                          or report.exists() and report.samefile(value)):
                raise ValueError("report_must_not_alias_an_input")


def write_report(path: Path, report: dict) -> None:
    # Replace the directory entry, never follow a pre-existing symlink or
    # truncate an inode that could also be somebody's source PDF hard link.
    descriptor, temporary = tempfile.mkstemp(prefix=".pdf-report-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(report, stream, indent=2)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def extract_text(path: Path, output: Path, tool: str, timeout: float) -> str:
    check_poppler_diagnostics(run([tool, "-enc", "UTF-8", str(path), str(output)], timeout))
    if output.stat().st_size > MAX_TEXT_BYTES:
        raise ValueError("extracted_text_exceeds_16MiB_budget")
    return output.read_text(encoding="utf-8")


def render(path: Path, page: int, prefix: Path, tool: str, timeout: float) -> Path:
    check_poppler_diagnostics(run([tool, "-f", str(page), "-l", str(page), "-scale-to", "1200",
         "-singlefile", "-png", str(path), str(prefix)], timeout))
    output = prefix.with_suffix(".png")
    from PIL import Image
    with Image.open(output) as image:
        image.load()
        if min(image.size) < 1 or max(image.size) > 1200:
            raise ValueError("invalid_render_dimensions")
    return output


def check_poppler_diagnostics(result: dict) -> None:
    # Poppler may exit 0 after silently dropping a font/content stream. Missing
    # CMaps in a relocated tool installation must not produce a false pass.
    if any(marker in result["stderr"] for marker in (b"Syntax Error", b"Internal Error")):
        raise ValueError("poppler_content_or_configuration_error")


def pixel_difference(a: Path, b: Path) -> float:
    from PIL import Image, ImageChops
    with Image.open(a) as first, Image.open(b) as second:
        if first.size != second.size:
            return 1.0
        channels = ImageChops.difference(first.convert("RGB"), second.convert("RGB")).split()
        maximum = ImageChops.lighter(ImageChops.lighter(channels[0], channels[1]), channels[2])
        histogram = maximum.histogram()
        return sum(histogram[25:]) / (first.width * first.height)


def mean_pixel_error(a: Path, b: Path) -> float:
    from PIL import Image, ImageChops, ImageStat
    with Image.open(a) as first, Image.open(b) as second:
        if first.size != second.size:
            return 255.0
        return sum(ImageStat.Stat(ImageChops.difference(
            first.convert("RGB"), second.convert("RGB"))).mean) / 3


def detached_stream_for_decode(stream):
    """Resolve decoder parameters on private containers, never reader objects.

    pypdf 6.10.0's filter dispatcher does not dereference DecodeParms before
    selecting the predictor. Its EncodedStreamObject also caches that result.
    Retain immutable encoded bytes, discard only the COPY's decoded cache,
    and resolve the small decoder graph (including soft masks and palettes).
    This deliberately does not clone the PDF document or repair its data.
    """
    from pypdf.generic import (ArrayObject, DecodedStreamObject, DictionaryObject,
                               EncodedStreamObject, IndirectObject, NameObject,
                               NullObject, StreamObject)

    remaining = 4096
    active = set()
    decoder_keys = ("/Filter", "/DecodeParms", "/ColorSpace", "/SMask", "/Mask")

    def copy_value(value, depth=0):
        nonlocal remaining
        if depth > 32 or remaining <= 0:
            raise ValueError("decoder_parameter_graph_exceeds_budget")
        remaining -= 1
        if isinstance(value, IndirectObject):
            identity = ("reference", id(value.pdf), value.idnum, value.generation)
        elif isinstance(value, (DictionaryObject, ArrayObject)):
            identity = ("container", id(value))
        else:
            return value
        if identity in active:
            raise ValueError("decoder_parameter_cycle")
        active.add(identity)
        try:
            if isinstance(value, IndirectObject):
                resolved = value.get_object()
                if resolved is None:
                    raise ValueError("decoder_parameter_unresolved")
                return copy_value(resolved, depth + 1)
            if isinstance(value, StreamObject):
                if len(value) > remaining:
                    raise ValueError("decoder_parameter_graph_exceeds_budget")
                remaining -= len(value)
                if not isinstance(value._data, bytes):
                    raise ValueError("decoder_stream_payload_not_immutable_bytes")
                result = EncodedStreamObject() if isinstance(value, EncodedStreamObject) else DecodedStreamObject()
                result.update(value)
                result._data = value._data
                # All non-decoder entries stay shallow and unchanged. Only
                # these fields are read recursively by the public image API.
                for key in decoder_keys:
                    if key in value:
                        result[NameObject(key)] = copy_value(value.raw_get(key), depth + 1)
                parameters = result.get("/DecodeParms")
                if parameters is not None and not isinstance(parameters, (DictionaryObject, ArrayObject, NullObject)):
                    raise ValueError("decoder_parameters_wrong_type")
                if isinstance(parameters, ArrayObject) and any(not isinstance(item, (DictionaryObject, NullObject)) for item in parameters):
                    raise ValueError("decoder_parameters_wrong_type")
                return result
            if isinstance(value, ArrayObject):
                if len(value) > remaining:
                    raise ValueError("decoder_parameter_graph_exceeds_budget")
                return ArrayObject(copy_value(item, depth + 1) for item in value)
            if len(value) > remaining:
                raise ValueError("decoder_parameter_graph_exceeds_budget")
            return DictionaryObject({key: copy_value(item, depth + 1) for key, item in value.items()})
        finally:
            active.remove(identity)

    if not isinstance(stream, StreamObject):
        raise ValueError("decoder_requires_stream")
    return copy_value(stream)


def decoded_stream_data(stream) -> bytes:
    """WORK verifiers must use this for predictor-aware decoded payloads."""
    return detached_stream_for_decode(stream).get_data()


def decoded_asset_image(asset):
    reference = asset.indirect_reference
    original = reference.get_object() if reference is not None else None
    if original is None:
        return asset.image
    image = detached_stream_for_decode(original)
    color_space = image.get("/ColorSpace")
    if hasattr(color_space, "get_object"):
        color_space = color_space.get_object()
    if (image is not None and not image.get("/Filter")
            and isinstance(color_space, list) and color_space
            and color_space[0] == "/Indexed"):
        # pypdf 6.10.0's unfiltered-image branch omits Indexed palettes.
        # Decode a detached, losslessly Flate-encoded copy through its public
        # image API. The PDF reader's objects and source file stay unchanged.
        return image.flate_encode().decode_as_image()
    return image.decode_as_image()


def image_fingerprints(page) -> list:
    # Compare decoded pixels so a lossless Flate re-encoding is not mistaken
    # for recompression damage. Sorting ignores resource renaming/nesting.
    if len(page.images) > 1000:
        raise ValueError("image_inventory_exceeds_budget")
    fingerprints = []
    for asset in page.images:
        source = decoded_asset_image(asset)
        if source.width * source.height > 40_000_000:
            raise ValueError("image_pixel_inventory_exceeds_budget")
        pixels = source.convert("RGBA")
        fingerprints.append((pixels.size, hashlib.sha256(pixels.tobytes()).hexdigest()))
    return sorted(fingerprints)


def verify(item: dict, directory: Path, tools: dict, timeout: float,
           source_only: bool) -> dict:
    from pypdf import PdfReader
    path = Path(item["path"])
    original_hash = digest(path)
    result = {"id": item["id"], "bytes": path.stat().st_size, "sha256": original_hash,
              "status": "passed", "checks": {}}
    try:
        qpdf = run([tools["qpdf"], "--check", str(path)], timeout, (0, 3) if source_only else (0,))
        result["checks"]["qpdf"] = {"exit_code": qpdf["code"], "seconds": qpdf["seconds"]}
        if qpdf["code"] == 3:
            result["status"] = "source_warnings"
        reader = PdfReader(path)
        count = len(reader.pages)
        result["pages"] = count
        if "page_count" in item and count != item["page_count"]:
            raise ValueError("page_count_mismatch")
        text_path = directory / "text.txt"
        text = extract_text(path, text_path, tools["pdftotext"], timeout)
        canonical = normalized(text)
        for expected in item.get("expected_text", []):
            if normalized(expected) not in canonical:
                raise ValueError("expected_text_missing")
        for absent in item.get("absent_text", []):
            if normalized(absent) in canonical:
                raise ValueError("removed_text_still_extractable")
        cursor = 0
        for expected in item.get("reading_order", []):
            position = canonical.find(normalized(expected), cursor)
            if position < 0:
                raise ValueError("reading_order_mismatch")
            cursor = position + len(normalized(expected))
        result["checks"]["text"] = {"characters": len(text), "expectations_passed": True}
        expected_fields = item.get("fields", {})
        if expected_fields:
            fields = reader.get_fields() or {}
            for name, expected in expected_fields.items():
                if name not in fields or str(fields[name].get("/V", "")) != expected:
                    raise ValueError("canonical_form_value_mismatch")
            result["checks"]["forms"] = {"verified_fields": len(expected_fields)}
        rendered = {}
        for page in item.get("pages", [1]):
            if page > count:
                raise ValueError("sample_page_out_of_range")
            rendered[page] = render(path, page, directory / f"page-{page}", tools["pdftoppm"], timeout)
        result["checks"]["rendered_pages"] = list(rendered)
        if item.get("reference"):
            reference = Path(item["reference"])
            if item.get("compare_image_pixels"):
                baseline = PdfReader(reference)
                if count != len(baseline.pages):
                    raise ValueError("image_reference_page_count_mismatch")
                for current_page, original_page in zip(reader.pages, baseline.pages):
                    if image_fingerprints(current_page) != image_fingerprints(original_page):
                        raise ValueError("embedded_image_pixels_changed")
                result["checks"]["embedded_image_pixels"] = {"identical": True, "pages": count}
            if item.get("compare_text"):
                before = extract_text(reference, directory / "reference-text.txt", tools["pdftotext"], timeout)
                agreement = sequence_agreement(before, text)
                result["checks"]["reading_order_agreement"] = agreement
                if agreement["truncated"] or agreement["score"] < item.get("minimum_text_agreement", 1.0):
                    raise ValueError("text_sequence_comparison_incomplete_or_below_threshold")
            comparisons = []
            for pair in item.get("compare_pages", []):
                output_page, source_page = pair["output"], pair["reference"]
                current = rendered.get(output_page) or render(path, output_page,
                    directory / f"page-{output_page}", tools["pdftoppm"], timeout)
                before = render(reference, source_page, directory / f"reference-{source_page}", tools["pdftoppm"], timeout)
                ratio = pixel_difference(current, before)
                mean_error = mean_pixel_error(current, before)
                comparisons.append({"output": output_page, "reference": source_page,
                                    "different_pixel_ratio": round(ratio, 8),
                                    "mean_channel_error_0_to_255": round(mean_error, 8)})
                if (ratio > pair.get("maximum_difference_ratio", 0.001)
                        or mean_error > pair.get("maximum_mean_pixel_error", 255.0)):
                    raise ValueError("unchanged_page_render_mismatch")
            result["checks"]["page_comparisons"] = comparisons
    except Exception as error:
        result["status"] = "failed"
        # Stable codes only. pypdf exceptions can include private source text.
        result["error"] = str(error) if isinstance(error, ValueError) and re.fullmatch(r"[a-z_0-9:.]+", str(error)) else type(error).__name__
    finally:
        result["input_unchanged"] = digest(path) == original_hash
        if not result["input_unchanged"]:
            result.update(status="failed", error="input_integrity_changed")
        # Extracted book text is transient. PNGs remain local for visual review.
        for output in directory.glob("*text.txt"):
            output.unlink()
    return result


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--output-directory", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=90)
    for name in ("qpdf", "pdftotext", "pdftoppm"):
        parser.add_argument(f"--{name}", default=os.environ.get(f"EMBER_{name.upper()}", name))
    args = parser.parse_args(argv)
    try:
        tools = {name: resolve_tool(getattr(args, name)) for name in ("qpdf", "pdftotext", "pdftoppm")}
        items, source_only = read_manifest(args.manifest.resolve())
        prepare_output(args.output_directory, items)
        report = {"schema": 1, "source_diagnostics_only": source_only, "files": []}
        for item in items:
            # A fresh exclusive directory prevents stale images from passing
            # validation and protects inputs from malicious/stale output links.
            directory = Path(tempfile.mkdtemp(prefix=item["id"] + "-", dir=args.output_directory))
            result = verify(item, directory, tools, args.timeout, source_only)
            report["files"].append(result)
            # Release reader/page/image reference cycles before the next PDF.
            gc.collect()
            print(f"{item['id']}: {result['status']}", flush=True)
            write_report(args.output_directory / "report.json", report)
        report["passed"] = all(item["status"] in ("passed", "source_warnings") for item in report["files"])
        write_report(args.output_directory / "report.json", report)
        return 0 if report["passed"] else 1
    except Exception as error:
        print(f"External PDF validation failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
