import Testing
@testable import LeporeloCore

@Suite struct TemplateOrientationTests {
    /// Full-page bleeding frames are exempt from the aspect bounds.
    static let exemptTemplateIDs: Set<String> = ["intro-1", "closing-1", "gallery-1"]

    @Test func orientationLabelMatchesRealAspectOnCanva() throws {
        let g = try TemplatesTests.canva()
        for t in TemplateCatalog.all where !Self.exemptTemplateIDs.contains(t.id) {
            let s = TemplateLayout.instantiate(t, geometry: g, dayKey: nil)
            for (f, slot) in zip(s.frames, t.frames) {
                let w = f.rect.size.width, h = f.rect.size.height
                switch slot.orientation {
                case .portrait: #expect(h / w >= 1.25 && h / w <= 1.8, "\(t.id) \(f.id) \(w)x\(h)")
                case .landscape: #expect(w / h >= 1.3 && w / h <= 1.8, "\(t.id) \(f.id) \(w)x\(h)")
                case .any: break
                }
            }
        }
    }
}
