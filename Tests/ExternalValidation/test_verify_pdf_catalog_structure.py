# SPDX-License-Identifier: MPL-2.0
"""Independent malformed-graph and read-only contract regression fixtures."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

from pypdf import PdfReader, PdfWriter
from pypdf.generic import (ArrayObject, DecodedStreamObject, DictionaryObject, NameObject, NumberObject,
                          TextStringObject)

MODULE = Path(__file__).resolve().parents[2] / "scripts" / "verify_pdf_catalog_structure.py"
spec = importlib.util.spec_from_file_location("catalog_oracles", MODULE)
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


def dictionary(**values):
    return DictionaryObject({NameObject("/" + key): value for key, value in values.items()})


def fixture(path, bad_page=False, bad_slot=False, bad_ocg=False):
    writer = PdfWriter()
    page = writer.add_blank_page(200, 200)
    root = dictionary(Type=NameObject("/StructTreeRoot"))
    root_ref = writer._add_object(root)
    element = dictionary(Type=NameObject("/StructElem"), S=NameObject("/P"),
                         P=root_ref, Pg=page.indirect_reference, K=NumberObject(0))
    element_ref = writer._add_object(element)
    if bad_page:
        # Real dictionary and indirect object, but outside the output page tree.
        element[NameObject("/Pg")] = writer._add_object(dictionary(Type=NameObject("/Page")))
    root[NameObject("/K")] = ArrayObject([element_ref])
    slot = writer._add_object(dictionary(S=NameObject("/P"))) if bad_slot else element_ref
    root[NameObject("/ParentTree")] = dictionary(Nums=ArrayObject([NumberObject(0), ArrayObject([slot])]))
    root[NameObject("/ParentTreeNextKey")] = NumberObject(1)
    page[NameObject("/StructParents")] = NumberObject(0)
    writer._root_object[NameObject("/StructTreeRoot")] = root_ref
    if bad_ocg:
        layer = writer._add_object(dictionary(Type=NameObject("/OCG"), Name=TextStringObject("private-name")))
        page[NameObject("/Resources")] = dictionary(Properties=dictionary(Layer=layer))
        writer._root_object[NameObject("/OCProperties")] = dictionary(OCGs=ArrayObject([]), D=dictionary(ON=ArrayObject([layer])))
    writer.write(path)


class PDFCatalogStructureOracleTests(unittest.TestCase):
    def test_only_exact_preexisting_unreachable_mcr_is_a_source_warning(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            source, output = folder / "source.pdf", folder / "output.pdf"
            writer = PdfWriter()
            page = writer.add_blank_page(200, 200)
            root = dictionary(Type=NameObject("/StructTreeRoot"))
            root_ref = writer._add_object(root)
            def form(content):
                value = DecodedStreamObject()
                value.set_data(content)
                value.update(dictionary(Type=NameObject("/XObject"), Subtype=NameObject("/Form"),
                                        StructParents=NumberObject(9), BBox=ArrayObject([NumberObject(0)] * 4)))
                return writer._add_object(value)
            declared = form(b"/P << /MCID 0 >> BDC EMC")
            painted = form(b"/P << /MCID 1 >> BDC EMC")
            paragraph = writer._add_object(dictionary(Type=NameObject("/StructElem"), S=NameObject("/P"), P=root_ref,
                K=dictionary(Type=NameObject("/MCR"), Pg=page.indirect_reference, Stm=declared, MCID=NumberObject(0))))
            root[NameObject("/K")] = ArrayObject([paragraph])
            root[NameObject("/ParentTree")] = dictionary(Nums=ArrayObject([NumberObject(9), ArrayObject([paragraph])]))
            writer._root_object[NameObject("/StructTreeRoot")] = root_ref
            page[NameObject("/Resources")] = dictionary(XObject=dictionary(Painted=painted))
            writer.write(source)
            writer.write(output)
            row = {"id": "opaque-1", "source": str(source), "source_indexes": [0],
                   "outputs": [{"path": str(output), "kind": "extract", "offset": 0}]}
            result = driver.verify_row(row)
            self.assertEqual(result["status"], "passed")
            warnings = result["outputs"][0]["source_warnings"]
            self.assertEqual(warnings["preexisting_source_mcr_stream_not_page_resource"], 1)
            self.assertEqual(warnings["preexisting_source_shared_form_struct_parent_key"], 1)
            # Changing that unreachable stream is an introduced defect; a
            # blanket exemption based on document ID or error count would miss it.
            declared.get_object().set_data(b"/P << /MCID 0 >> BDC changed EMC")
            writer.write(output)
            result = driver.verify_row(row)
            self.assertEqual(result["status"], "failed")
            self.assertIn("mcr_stream_not_page_resource", result["outputs"][0]["errors"])
            declared.get_object().set_data(b"/P << /MCID 0 >> BDC EMC")
            painted.get_object()[NameObject("/StructParents")] = NumberObject(10)
            writer.write(output)
            result = driver.verify_row(row)
            self.assertEqual(result["status"], "failed")
            self.assertIn("missing_parent_tree_entry", result["outputs"][0]["errors"],
                          "A known stale MCR never excuses a new broken painted-Form parent key.")

    def test_valid_parent_slot_passes_and_bad_page_and_slot_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.pdf"
            fixture(path)
            self.assertFalse(driver.Audit(PdfReader(path)).run().errors)
            fixture(path, bad_page=True)
            self.assertIn("dangling_page_reference", driver.Audit(PdfReader(path)).run().errors)
            fixture(path, bad_slot=True)
            errors = driver.Audit(PdfReader(path)).run().errors
            self.assertIn("mcid_parent_slot_mismatch", errors)
            self.assertIn("parent_tree_target_not_struct_element", errors)
            fixture(path)
            reader = PdfReader(path)
            # An outline/open-action array must not introduce an orphan page.
            reader.root_object[NameObject("/OpenAction")] = ArrayObject([
                dictionary(Type=NameObject("/Page")), NameObject("/Fit")])
            self.assertIn("dangling_page_reference", driver.Audit(reader).run().errors)
            # Empty /K and an omitted /K are equivalent for metadata-only
            # elements. Normalizing that representation must not hide loss of
            # the actual /Info or /Metadata payload.
            metadata = dictionary(S=NameObject("/Document"), Info=dictionary(Producer=TextStringObject("opaque")))
            reader.root_object["/StructTreeRoot"][NameObject("/K")] = metadata
            expected = driver.unpaged_metadata_tags(reader, driver.Budget())
            metadata[NameObject("/K")] = ArrayObject([])
            self.assertEqual(driver.unpaged_metadata_tags(reader, driver.Budget()), expected)
            metadata[NameObject("/Info")] = dictionary(Producer=TextStringObject("changed"))
            self.assertNotEqual(driver.unpaged_metadata_tags(reader, driver.Budget()), expected)

    def test_ocg_must_be_in_catalog_and_configuration_cannot_use_unknown_group(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.pdf"
            fixture(path, bad_ocg=True)
            errors = driver.Audit(PdfReader(path)).run().errors
            self.assertIn("painting_ocg_missing_from_catalog", errors)
            self.assertIn("layer_config_unknown_ocg", errors)

    def test_budget_exhaustion_and_tag_cycle_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.pdf"
            fixture(path)
            with self.assertRaisesRegex(driver.InvalidGraph, "graph_budget_exceeded"):
                driver.Audit(PdfReader(path), maximum=1).run()
            reader = PdfReader(path)
            root = reader.root_object["/StructTreeRoot"]
            element = root["/K"][0].get_object()
            element[NameObject("/K")] = ArrayObject([root["/K"][0]])
            with self.assertRaisesRegex(driver.InvalidGraph, "struct_tree_cycle"):
                driver.Audit(reader).run()

    def test_attachment_loss_is_failure_source_unchanged_and_report_cannot_alias(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            source, output = folder / "source.pdf", folder / "output.pdf"
            fixture(output)
            writer = PdfWriter(clone_from=output)
            writer.add_attachment("opaque.bin", b"exact-private-payload")
            writer.write(source)
            before = source.read_bytes()
            row = {"id": "opaque-1", "source": str(source), "source_indexes": [0],
                   "outputs": [{"path": str(output), "kind": "extract", "offset": 0}]}
            result = driver.verify_row(row)
            self.assertEqual(result["status"], "failed")
            self.assertIn("source_attachment_payload_missing", result["outputs"][0]["errors"])
            self.assertTrue(result["source_unchanged"])
            with self.assertRaisesRegex(ValueError, "report_must_not_alias"):
                driver.write_report(source, result, [row])
            self.assertEqual(source.read_bytes(), before)
            self.assertNotIn("private-payload", str(result))
            self.assertNotIn(str(folder), str(result))
            row["signed_original"] = True
            result = driver.verify_row(row)
            self.assertIn("signed_original_exact_attachment_missing", result["outputs"][0]["errors"])
            reader = PdfReader(output)
            reader.root_object[NameObject("/AcroForm")] = dictionary(Fields=ArrayObject([
                dictionary(FT=NameObject("/Sig"), V=dictionary(ByteRange=ArrayObject([NumberObject(0)])))]))
            audit = driver.Audit(reader)
            audit.unsigned()
            self.assertIn("assembled_output_retains_live_signature", audit.errors)


if __name__ == "__main__":
    unittest.main()
