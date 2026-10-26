import Testing
@testable import LeporeloCore

@Suite struct TemplateOrientationTests {
    @Test func orientationLabelMatchesRealAspectOnCanva() throws {
        let g = try TemplatesTests.canva()
        for t in TemplateCatalog.all {
            let s = TemplateLayout.instantiate(t, geometry: g, dayKey: nil)
            for (f, slot) in zip(s.frames, t.frames) {
                let w = f.rect.size.width, h = f.rect.size.height
                switch slot.orientation {
                case .portrait: #expect(h / w >= 1.25, "\(t.id) \(f.id) \(w)x\(h)")
                case .landscape: #expect(w / h >= 1.3, "\(t.id) \(f.id) \(w)x\(h)")
                case .any: break
                }
            }
        }
    }

    @Test func gallery3LandscapesAreCloseToThreeByTwo() throws {
        let g = try TemplatesTests.canva()
        let s = TemplateLayout.instantiate(TemplateCatalog.template(id: "gallery-3")!, geometry: g, dayKey: nil)
        for f in s.frames where f.id != "photo1" {
            let a = f.rect.size.width / f.rect.size.height
            #expect(a >= 1.3 && a <= 1.8, "\(f.id) \(a)")
        }
    }
}
