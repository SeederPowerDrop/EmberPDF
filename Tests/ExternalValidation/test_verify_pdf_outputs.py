# SPDX-License-Identifier: MPL-2.0
"""Failure-path checks for the independent PDF validation driver."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace

MODULE = Path(__file__).resolve().parents[2] / "scripts" / "verify_pdf_outputs.py"
spec = importlib.util.spec_from_file_location("pdf_oracles", MODULE)
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


class PDFOracleDriverTests(unittest.TestCase):
    class ObjectStore:
        def __init__(self):
            self.values = {}

        def reference(self, value):
            from pypdf.generic import IndirectObject
            number = len(self.values) + 1
            self.values[number] = value
            return IndirectObject(number, 0, self)

        def get_object(self, reference):
            return self.values[reference.idnum]

    @staticmethod
    def predictor_image(samples=b"\x10\x40\x80\xc0", predictor=15, parameters="direct", store=None):
        import zlib
        from pypdf.generic import ArrayObject, DictionaryObject, EncodedStreamObject, NameObject, NumberObject
        store = store or PDFOracleDriverTests.ObjectStore()
        image = EncodedStreamObject()
        # Two PNG rows, each with an explicit filter-None byte.
        image._data = zlib.compress(b"\x00" + samples[:2] + b"\x00" + samples[2:])
        values = {"/Predictor": NumberObject(predictor), "/Columns": NumberObject(2),
                  "/Colors": NumberObject(1), "/BitsPerComponent": NumberObject(8)}
        params = DictionaryObject({NameObject(key): value for key, value in values.items()})
        filters = NameObject("/FlateDecode")
        if parameters == "indirect":
            params = store.reference(params)
        elif parameters == "array":
            params = store.reference(ArrayObject([store.reference(params)]))
            filters = store.reference(ArrayObject([NameObject("/FlateDecode")]))
        elif parameters == "indirect-scalars":
            params = DictionaryObject({key: store.reference(value) for key, value in params.items()})
            params = store.reference(params)
        for key, value in {"/Type": NameObject("/XObject"), "/Subtype": NameObject("/Image"),
                           "/Width": NumberObject(2), "/Height": NumberObject(2),
                           "/BitsPerComponent": NumberObject(8), "/ColorSpace": NameObject("/DeviceGray"),
                           "/Filter": filters, "/DecodeParms": params}.items():
            image[NameObject(key)] = value
        return image

    @staticmethod
    def rgba(stream):
        return driver.decoded_asset_image(SimpleNamespace(indirect_reference=stream)).convert("RGBA").tobytes()

    def test_direct_and_indirect_predictor_dictionary_and_array_have_exact_payload_and_rgba(self):
        samples = b"\x10\x40\x80\xc0"
        expected = b"".join(bytes([value, value, value, 255]) for value in samples)
        for shape in ("direct", "indirect", "array", "indirect-scalars"):
            with self.subTest(shape=shape):
                image = self.predictor_image(parameters=shape)
                self.assertEqual(driver.decoded_stream_data(image), samples)
                self.assertEqual(self.rgba(image), expected)

    def test_indirect_soft_mask_parameters_preserve_exact_alpha(self):
        from pypdf.generic import NameObject
        samples, alpha = b"\x22\x44\x66\x88", b"\x00\x55\xaa\xff"
        expected = b"".join(bytes([sample, sample, sample, opacity]) for sample, opacity in zip(samples, alpha))
        for shape in ("direct", "indirect", "array"):
            with self.subTest(shape=shape):
                store = self.ObjectStore()
                main = self.predictor_image(samples, parameters=shape, store=store)
                mask = self.predictor_image(alpha, parameters=shape, store=store)
                main[NameObject("/SMask")] = store.reference(mask)
                self.assertEqual(driver.decoded_stream_data(mask), alpha)
                self.assertEqual(self.rgba(main), expected)

    def test_changed_predictor_samples_and_alpha_are_not_hidden(self):
        from pypdf.generic import NameObject
        baseline = self.predictor_image(parameters="indirect")
        wrong_predictor = self.predictor_image(predictor=1, parameters="indirect")
        changed_samples = self.predictor_image(b"\xc0\x80\x40\x10", parameters="indirect")
        self.assertNotEqual(driver.decoded_stream_data(baseline), driver.decoded_stream_data(wrong_predictor))
        self.assertNotEqual(self.rgba(baseline), self.rgba(wrong_predictor))
        self.assertNotEqual(self.rgba(baseline), self.rgba(changed_samples))
        baseline[NameObject("/SMask")] = self.predictor_image(b"\x00\x55\xaa\xff", parameters="indirect")
        changed_samples[NameObject("/SMask")] = self.predictor_image(b"\xff\xaa\x55\x00", parameters="indirect")
        # Match color samples so this negative isolates the soft-mask change.
        changed_samples._data = baseline._data
        self.assertNotEqual(self.rgba(baseline), self.rgba(changed_samples))

    def test_input_dictionaries_encoded_bytes_and_existing_decoded_caches_stay_unchanged(self):
        from pypdf.generic import DecodedStreamObject, NameObject
        store = self.ObjectStore()
        main = self.predictor_image(parameters="array", store=store)
        mask = self.predictor_image(parameters="indirect", store=store)
        main[NameObject("/SMask")] = store.reference(mask)
        for stream in (main, mask):
            stream.decoded_self = DecodedStreamObject()
            stream.decoded_self.set_data(b"existing decoded cache must not be used or changed")
        snapshot = [(tuple(stream.items()), stream._data, stream.decoded_self, stream.decoded_self._data)
                    for stream in (main, mask)]
        self.assertEqual(driver.decoded_stream_data(main), b"\x10\x40\x80\xc0")
        self.assertEqual(len(self.rgba(main)), 16)
        for stream, (entries, encoded, cache, cached) in zip((main, mask), snapshot):
            self.assertEqual(tuple(stream.items()), entries)
            self.assertIs(stream._data, encoded)
            self.assertIs(stream.decoded_self, cache)
            self.assertIs(stream.decoded_self._data, cached)

    def test_indirect_decode_parameter_cycles_and_soft_mask_cycles_are_refused(self):
        from pypdf.generic import ArrayObject, NameObject
        store = self.ObjectStore()
        cycle = ArrayObject()
        cycle.append(store.reference(cycle))
        image = self.predictor_image()
        image[NameObject("/DecodeParms")] = store.reference(cycle)
        with self.assertRaisesRegex(ValueError, "decoder_parameter_cycle"):
            driver.decoded_stream_data(image)
        image = self.predictor_image()
        image[NameObject("/SMask")] = image
        with self.assertRaisesRegex(ValueError, "decoder_parameter_cycle"):
            self.rgba(image)

    def test_decode_parameter_depth_and_node_limits_refuse_without_decoding(self):
        from pypdf.generic import ArrayObject, DictionaryObject, NameObject, NullObject
        image, store = self.predictor_image(), self.ObjectStore()
        value = DictionaryObject()
        for _ in range(40):
            value = store.reference(value)
        image[NameObject("/DecodeParms")] = value
        with self.assertRaisesRegex(ValueError, "decoder_parameter_graph_exceeds_budget"):
            driver.decoded_stream_data(image)
        image[NameObject("/DecodeParms")] = ArrayObject([NullObject() for _ in range(4097)])
        with self.assertRaisesRegex(ValueError, "decoder_parameter_graph_exceeds_budget"):
            driver.decoded_stream_data(image)

    @staticmethod
    def indexed_image(samples=b"\x00\x01", palette=b"\xff\x00\x00\x00\xff\x00"):
        from pypdf.generic import ArrayObject, ByteStringObject, DecodedStreamObject, NameObject, NumberObject
        image = DecodedStreamObject()
        image.set_data(samples)
        for key, value in {"/Type": NameObject("/XObject"), "/Subtype": NameObject("/Image"),
                           "/Width": NumberObject(2), "/Height": NumberObject(1),
                           "/BitsPerComponent": NumberObject(8),
                           "/ColorSpace": ArrayObject([NameObject("/Indexed"), NameObject("/DeviceRGB"),
                                                       NumberObject(1), ByteStringObject(palette)])}.items():
            image[NameObject(key)] = value
        return image

    def test_indexed_pixels_match_across_lossless_filter_changes_without_mutating_input(self):
        raw = self.indexed_image()
        compressed = raw.flate_encode()
        expected = compressed.decode_as_image().convert("RGBA").tobytes()
        actual = driver.decoded_asset_image(SimpleNamespace(indirect_reference=raw)).convert("RGBA").tobytes()
        self.assertEqual(actual, expected)
        self.assertEqual(actual, b"\xff\x00\x00\xff\x00\xff\x00\xff")
        self.assertNotIn("/Filter", raw)
        self.assertEqual(raw.get_data(), b"\x00\x01")

    def test_indexed_sample_and_palette_changes_still_fail_pixel_equality(self):
        def pixels(image):
            return driver.decoded_asset_image(SimpleNamespace(indirect_reference=image)).convert("RGBA").tobytes()
        baseline = pixels(self.indexed_image())
        self.assertNotEqual(baseline, pixels(self.indexed_image(samples=b"\x01\x00")))
        self.assertNotEqual(baseline, pixels(self.indexed_image(palette=b"\x00\x00\xff\x00\xff\x00")))

    def test_missing_required_tool_is_failure(self):
        with self.assertRaisesRegex(ValueError, "required_tool_missing"):
            driver.resolve_tool("/nonexistent/ember-qpdf")

    def test_reordered_words_do_not_score_as_identical(self):
        score = driver.sequence_agreement("first paragraph second paragraph", "second paragraph first paragraph")
        self.assertLess(score["score"], 1)
        self.assertFalse(score["truncated"])

    def test_oversized_sequence_is_explicitly_incomplete(self):
        self.assertTrue(driver.sequence_agreement("word " * 3001, "word " * 3001)["truncated"])

    def test_manifest_cannot_write_outside_its_output_directory(self):
        with tempfile.TemporaryDirectory() as folder:
            manifest = Path(folder) / "manifest.json"
            manifest.write_text(json.dumps({"files": [{"id": "../escape", "path": "a.pdf"}]}))
            with self.assertRaisesRegex(ValueError, "safe_names"):
                driver.read_manifest(manifest)

    def test_external_tool_error_does_not_become_success(self):
        with self.assertRaisesRegex(ValueError, "external_tool_exit_7"):
            driver.run(["/bin/sh", "-c", "exit 7"], 1)

    def test_zero_exit_with_missing_font_or_cmap_is_not_a_pass(self):
        with self.assertRaisesRegex(ValueError, "poppler_content_or_configuration_error"):
            driver.check_poppler_diagnostics({"code": 0, "stderr": b"Syntax Error: Missing language pack"})

    def test_existing_report_alias_is_refused_before_any_write(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / "source.pdf"
            source.write_bytes(b"original bytes")
            (root / "report.json").symlink_to(source)
            with self.assertRaisesRegex(ValueError, "must_not_alias"):
                driver.prepare_output(root, [{"path": str(source)}])
            self.assertEqual(source.read_bytes(), b"original bytes")

    def test_atomic_report_replaces_links_without_truncating_their_target(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / "source.pdf"
            source.write_bytes(b"original bytes")
            report = root / "report.json"
            report.hardlink_to(source)
            driver.write_report(report, {"passed": True})
            self.assertEqual(source.read_bytes(), b"original bytes")
            self.assertEqual(json.loads(report.read_text()), {"passed": True})


if __name__ == "__main__":
    unittest.main()
