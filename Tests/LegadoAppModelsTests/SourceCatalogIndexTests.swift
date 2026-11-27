import Foundation
import Testing
import LegadoCore
@testable import LegadoAppModels

@MainActor
struct SourceCatalogIndexTests {
    @Test func catalogIndexTracksGroupsCountsAndDirectLookup() async {
        var alpha = BookSource(bookSourceUrl: "https://alpha.example.com", bookSourceName: "星辰小说")
        alpha.bookSourceGroup = "玄幻,精选"
        alpha.enabled = true
        alpha.weight = 10

        var beta = BookSource(bookSourceUrl: "https://beta.example.com", bookSourceName: "古风书屋")
        beta.bookSourceGroup = "精选"
        beta.enabled = false
        beta.weight = 5

        var gamma = BookSource(bookSourceUrl: "https://gamma.example.com", bookSourceName: "散落站")
        gamma.bookSourceGroup = nil
        gamma.enabled = true
        gamma.weight = 1

        let model = SourceLibraryModel.demo(sources: [alpha, beta, gamma])
        await model.load()

        #expect(model.enabledCount == 2)
        #expect(model.groups == ["精选", "玄幻"])
        #expect(model.groupCounts["精选"] == 2)
        #expect(model.groupCounts["玄幻"] == 1)
        #expect(model.catalogIndex.ungroupedCount == 1)
        #expect(model.entries(inGroup: "精选").map(\.id) == [alpha.id, beta.id])
        #expect(model.source(id: beta.id)?.bookSourceName == "古风书屋")

        let revisionBefore = model.catalogRevision
        await model.setEnabled(false, for: alpha.id)
        #expect(model.catalogRevision != revisionBefore)
        #expect(model.enabledCount == 1)
        #expect(model.source(id: alpha.id)?.enabled == false)

        await model.remove(sourceIDs: [beta.id])
        #expect(model.groupCounts["精选"] == 1)
        #expect(model.entries(inGroup: "精选").map(\.id) == [alpha.id])
    }

    @Test func catalogIndexFiltersAndSortsLargeListsAccurately() {
        let sources: [BookSource] = (0..<1500).map { i in
            var s = BookSource(
                bookSourceUrl: "https://site-\(i).example.org",
                bookSourceName: i == 777 ? "目标独角兽书源" : "测试书源 \(i)"
            )
            s.bookSourceGroup = i % 3 == 0 ? "玄幻" : (i % 3 == 1 ? "都市" : nil)
            s.enabled = i % 2 == 0
            s.weight = 1500 - i
            s.respondTime = Int64(i * 10)
            s.customOrder = i
            return s
        }

        let index = SourceCatalogIndex(sources: sources)
        #expect(index.entries.count == 1500)
        #expect(index.enabledCount == 750)
        #expect(index.ungroupedCount == 500)

        let byKeyword = index.query(group: nil, searchText: "独角兽", sort: .manual, descending: false)
        #expect(byKeyword.map(\.id) == ["https://site-777.example.org"])

        let byHost = index.query(group: "都市", searchText: "SITE-100.EXAMPLE", sort: .manual, descending: false)
        #expect(byHost.map(\.id) == ["https://site-100.example.org"])

        let sortedWeight = index.query(group: "", searchText: "", sort: .weight, descending: false)
        #expect(sortedWeight.count == 500)
        #expect(sortedWeight.first?.weight == 1)
        #expect(sortedWeight.last?.weight == 1498)
    }
}
