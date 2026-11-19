// SPDX-License-Identifier: MPL-2.0

import AppKit
import XCTest
@testable import HwattakPDF

final class PDFComparisonGeometryTests: XCTestCase {
    func testMixedSplitFramesKeepFourDocumentsWithoutOverlap() {
        let ids = (0..<4).map { _ in UUID() }
        let tree = PDFComparisonSplit.split(id: UUID(), axis: .sideBySide, fraction: 0.5,
            first: .split(id: UUID(), axis: .stacked, fraction: 0.4,
                first: .document(ids[0]), second: .document(ids[2])),
            second: .split(id: UUID(), axis: .sideBySide, fraction: 0.6,
                first: .document(ids[1]), second: .document(ids[3])))
        let size = CGSize(width: 1_400, height: 900)
        let result = PDFComparisonGeometry(tree: tree, size: size)
        XCTAssertEqual(Set(result.panels.keys), Set(ids))
        XCTAssertEqual(result.dividers.count, 3)
        let a = result.panels[ids[0]]!, b = result.panels[ids[1]]!
        let c = result.panels[ids[2]]!, d = result.panels[ids[3]]!
        XCTAssertEqual(a.minX, c.minX)
        XCTAssertLessThan(a.maxY, c.minY)
        XCTAssertEqual(b.minY, d.minY)
        XCTAssertLessThan(b.maxX, d.minX)
        assertTiling(result, size: size)
    }

    func testSmallWindowsCannotProduceNegativeOrOverlappingFrames() {
        let ids = (0..<4).map { _ in UUID() }
        var config = PDFComparisonConfiguration(selectedDocumentIDs: ids)
        config.applyGridPreset()
        for size in [CGSize(width: 300,height: 160), .zero, CGSize(width: 5,height: 5)] {
            assertTiling(PDFComparisonGeometry(tree: config.effectiveSplitTree,size: size),size: size)
        }
    }

    func testDividerClampReservesSpaceForNestedChildren() {
        let ids = (0..<3).map { _ in UUID() }
        let root = UUID()
        let tree = PDFComparisonSplit.split(id: root,axis: .sideBySide,fraction: 0.99,
            first: .document(ids[0]),
            second: .split(id: UUID(),axis: .sideBySide,fraction: 0.5,
                first: .document(ids[1]),second: .document(ids[2])))
        let result = PDFComparisonGeometry(tree: tree,size: CGSize(width: 1_000,height: 500))
        XCTAssertGreaterThanOrEqual(result.panels[ids[1]]!.width,180-0.001)
        XCTAssertGreaterThanOrEqual(result.panels[ids[2]]!.width,180-0.001)
        let divider = result.dividers.first { $0.id == root }!
        XCTAssertLessThan(divider.maximumFraction,0.7)
        XCTAssertEqual(divider.fraction,divider.maximumFraction)
    }

    func testDropDistinguishesEdgesFromCenter() {
        let size = CGSize(width: 400,height: 600)
        XCTAssertEqual(PDFComparisonDropLocation.resolve(point:CGPoint(x:5,y:300),size:size),.edge(.left))
        XCTAssertEqual(PDFComparisonDropLocation.resolve(point:CGPoint(x:395,y:300),size:size),.edge(.right))
        XCTAssertEqual(PDFComparisonDropLocation.resolve(point:CGPoint(x:200,y:5),size:size),.edge(.above))
        XCTAssertEqual(PDFComparisonDropLocation.resolve(point:CGPoint(x:200,y:595),size:size),.edge(.below))
        XCTAssertEqual(PDFComparisonDropLocation.resolve(point:CGPoint(x:200,y:300),size:size),.swap)
    }

    func testCanvasDropUsesTargetLocalCoordinatesAndIgnoresDividerSourceAndOutside() {
        let a = UUID(), b = UUID()
        let tree = PDFComparisonSplit.split(id: UUID(), axis: .sideBySide, fraction: 0.5,
            first: .document(a), second: .document(b))
        let geometry = PDFComparisonGeometry(tree: tree, size: CGSize(width: 810, height: 600))
        let center = geometry.dropDestination(at: CGPoint(x: 610, y: 300), excluding: a)
        XCTAssertEqual(center?.id, b)
        XCTAssertEqual(center?.location, .swap)
        XCTAssertEqual(geometry.dropDestination(at: CGPoint(x: 610, y: 590), excluding: a)?.location, .edge(.below))
        XCTAssertNil(geometry.dropDestination(at: CGPoint(x: 200, y: 300), excluding: a))
        XCTAssertNil(geometry.dropDestination(at: CGPoint(x: 405, y: 300), excluding: a))
        XCTAssertNil(geometry.dropDestination(at: CGPoint(x: 900, y: 300), excluding: a))
    }

    func testEveryVisibleDropGuideMatchesItsDropActionInNarrowWideAndTallPanels() {
        for size in [CGSize(width: 180, height: 140), CGSize(width: 220, height: 900),
                     CGSize(width: 1_600, height: 380), CGSize(width: 700, height: 600)] {
            for location in PDFComparisonDropLocation.guides {
                let point = location.guideCenter(in: size)
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(point))
                XCTAssertEqual(PDFComparisonDropLocation.resolve(point: point, size: size), location)
            }
        }
    }

    func testGuideTargetsStillResolveAfterMixedSplitsOffsetTheirPanels() throws {
        let ids = (0..<4).map { _ in UUID() }
        let tree = PDFComparisonSplit.split(id: UUID(), axis: .sideBySide, fraction: 0.35,
            first: .split(id: UUID(), axis: .stacked, fraction: 0.55,
                          first: .document(ids[0]), second: .document(ids[1])),
            second: .split(id: UUID(), axis: .sideBySide, fraction: 0.7,
                           first: .document(ids[2]), second: .document(ids[3])))
        let geometry = PDFComparisonGeometry(tree: tree, size: CGSize(width: 1_600, height: 850))
        for targetID in ids.dropFirst() {
            let frame = try XCTUnwrap(geometry.panels[targetID])
            for location in PDFComparisonDropLocation.guides {
                let local = location.guideCenter(in: frame.size)
                let canvas = CGPoint(x: frame.minX + local.x, y: frame.minY + local.y)
                let destination = geometry.dropDestination(at: canvas, excluding: ids[0])
                XCTAssertEqual(destination?.id, targetID)
                XCTAssertEqual(destination?.location, location)
            }
        }
    }

    func testDropPreviewFramesRemainNonnegativeInTransientTinyCanvases() {
        for size in [CGSize.zero, CGSize(width: 5, height: 5), CGSize(width: 180, height: 140)] {
            for location in PDFComparisonDropLocation.guides {
                let frame = location.previewRect(in: size)
                XCTAssertGreaterThanOrEqual(frame.width, 0)
                XCTAssertGreaterThanOrEqual(frame.height, 0)
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertGreaterThanOrEqual(frame.minY, 0)
                XCTAssertLessThanOrEqual(frame.maxX, size.width)
                XCTAssertLessThanOrEqual(frame.maxY, size.height)
            }
        }
    }

    private func assertTiling(_ result: PDFComparisonGeometry,size:CGSize,file:StaticString = #filePath,line:UInt = #line) {
        let frames = Array(result.panels.values) + result.dividers.map(\.rect)
        for (index,rect) in frames.enumerated() {
            XCTAssertGreaterThanOrEqual(rect.width,0,file:file,line:line)
            XCTAssertGreaterThanOrEqual(rect.height,0,file:file,line:line)
            XCTAssertGreaterThanOrEqual(rect.minX,0,file:file,line:line)
            XCTAssertGreaterThanOrEqual(rect.minY,0,file:file,line:line)
            XCTAssertLessThanOrEqual(rect.maxX,size.width + 0.001,file:file,line:line)
            XCTAssertLessThanOrEqual(rect.maxY,size.height + 0.001,file:file,line:line)
            for other in frames.dropFirst(index+1) {
                let intersection = rect.intersection(other)
                XCTAssertTrue(intersection.isNull || intersection.width * intersection.height < 0.001,file:file,line:line)
            }
        }
        XCTAssertEqual(frames.reduce(0) { $0 + $1.width*$1.height },size.width*size.height,accuracy:0.01,file:file,line:line)
    }
}
