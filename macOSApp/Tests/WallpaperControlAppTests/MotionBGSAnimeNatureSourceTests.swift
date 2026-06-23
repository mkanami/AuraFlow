import Foundation
import Testing
@testable import WallpaperControlApp

@Test func motionBGSListingPageParsesItemsAndNextPage() {
    let html = """
    <html>
      <head>
        <link href=https://motionbgs.com/tag:anime-nature/2/ rel=next>
      </head>
      <body>
        <div class=tmb>
          <a title="Calm Blue Lake live wallpaper" href=/calm-blue-lake>
            <figure><img src=/i/c/364x205/media/9472/calm-blue-lake.3840x2160.jpg></figure>
            <span class=ttl>Calm Blue Lake</span>
            <span class=frm> 4K </span>
          </a>
        </div>
      </body>
    </html>
    """

    let page = MotionBGSParser.parseListingPage(
        html: html,
        baseURL: URL(string: "https://motionbgs.com/")!
    )

    #expect(page.items.count == 1)
    #expect(page.items.first?.title == "Calm Blue Lake")
    #expect(page.items.first?.pageURL.absoluteString == "https://motionbgs.com/calm-blue-lake")
    #expect(page.nextPath == "tag:anime-nature/2/")
}

@Test func motionBGSDetailPageBuildsDownloadableWallpaper() {
    let item = MotionBGSListItem(
        title: "Calm Blue Lake",
        pageURL: URL(string: "https://motionbgs.com/calm-blue-lake")!,
        previewImageURL: URL(string: "https://motionbgs.com/i/c/364x205/media/9472/calm-blue-lake.3840x2160.jpg")
    )
    let html = """
    <html>
      <head>
        <meta content=https://motionbgs.com/media/9472/calm-blue-lake.3840x2160.jpg property=og:image>
      </head>
      <body>
        <h1><span>Calm Blue Lake</span> Live Wallpaper</h1>
        <li><div><a href=/tag:anime-nature/>Anime Nature</a></div></li>
        <section class=dl>
          <a href=/dl/4k/9472 rel=nofollow target=_blank>
            <div class="text-lg mb-1"><span class=font-bold>4K</span> Wallpaper (18.1Mb)</div>
            <div class=text-xs>3840x2160 mp4 file</div>
          </a>
          <a href=/dl/hd/9472 rel=nofollow target=_blank>
            <div class="text-lg mb-1"><span class=font-bold>HD</span> Wallpaper (10.9Mb)</div>
            <div class=text-xs>1920x1080 mp4 file</div>
          </a>
        </section>
      </body>
    </html>
    """

    let wallpaper = MotionBGSParser.parseDetailPage(
        html: html,
        item: item,
        baseURL: URL(string: "https://motionbgs.com/")!
    )

    #expect(wallpaper?.id == "motionbgs-anime-nature-calm-blue-lake")
    #expect(wallpaper?.title == "Calm Blue Lake")
    #expect(wallpaper?.category == "Anime Nature")
    #expect(wallpaper?.attribution == "MotionBGS")
    #expect(wallpaper?.sources.map(\.url.absoluteString) == [
        "https://motionbgs.com/dl/4k/9472",
        "https://motionbgs.com/dl/hd/9472",
    ])
}
