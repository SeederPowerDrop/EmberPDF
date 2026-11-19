// SPDX-License-Identifier: MPL-2.0

// CoreGraphics imports CGPDF references as OpaquePointer in older SDKs and
// RawRepresentable wrappers around that pointer in newer SDKs. Keep graph
// identity independent of the SDK without relying on compiler versions or
// the memory layout of an imported type. Identities are valid only while the
// owning CGPDFDocument is retained; they are never persisted across documents.
func pdfReferenceIdentity(_ reference: OpaquePointer) -> UInt {
    UInt(bitPattern: reference)
}

func pdfReferenceIdentity<Reference: RawRepresentable>(_ reference: Reference) -> UInt
where Reference.RawValue == OpaquePointer {
    UInt(bitPattern: reference.rawValue)
}
