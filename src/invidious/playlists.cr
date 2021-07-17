struct PlaylistVideo
  include DB::Serializable

  property title : String
  property id : String
  property author : String
  property ucid : String
  property length_seconds : Int32
  property published : Time
  property plid : String
  property index : Int64
  property live_now : Bool

  def to_xml(auto_generated, xml : XML::Builder)
    xml.element("entry") do
      xml.element("id") { xml.text "yt:video:#{self.id}" }
      xml.element("yt:videoId") { xml.text self.id }
      xml.element("yt:channelId") { xml.text self.ucid }
      xml.element("title") { xml.text self.title }
      xml.element("link", rel: "alternate", href: "#{HOST_URL}/watch?v=#{self.id}")

      xml.element("author") do
        if auto_generated
          xml.element("name") { xml.text self.author }
          xml.element("uri") { xml.text "#{HOST_URL}/channel/#{self.ucid}" }
        else
          xml.element("name") { xml.text author }
          xml.element("uri") { xml.text "#{HOST_URL}/channel/#{ucid}" }
        end
      end

      xml.element("content", type: "xhtml") do
        xml.element("div", xmlns: "http://www.w3.org/1999/xhtml") do
          xml.element("a", href: "#{HOST_URL}/watch?v=#{self.id}") do
            xml.element("img", src: "#{HOST_URL}/vi/#{self.id}/mqdefault.jpg")
          end
        end
      end

      xml.element("published") { xml.text self.published.to_s("%Y-%m-%dT%H:%M:%S%:z") }

      xml.element("media:group") do
        xml.element("media:title") { xml.text self.title }
        xml.element("media:thumbnail", url: "#{HOST_URL}/vi/#{self.id}/mqdefault.jpg",
          width: "320", height: "180")
      end
    end
  end

  def to_xml(auto_generated, xml : XML::Builder? = nil)
    if xml
      to_xml(auto_generated, xml)
    else
      XML.build do |json|
        to_xml(auto_generated, xml)
      end
    end
  end

  def to_json(locale, json : JSON::Builder, index : Int32?)
    json.object do
      json.field "title", self.title
      json.field "videoId", self.id

      json.field "author", self.author
      json.field "authorId", self.ucid
      json.field "authorUrl", "/channel/#{self.ucid}"

      json.field "videoThumbnails" do
        generate_thumbnails(json, self.id)
      end

      if index
        json.field "index", index
        json.field "indexId", self.index.to_u64.to_s(16).upcase
      else
        json.field "index", self.index
      end

      json.field "lengthSeconds", self.length_seconds
    end
  end

  def to_json(locale, json : JSON::Builder? = nil, index : Int32? = nil)
    if json
      to_json(locale, json, index: index)
    else
      JSON.build do |json|
        to_json(locale, json, index: index)
      end
    end
  end
end

struct Playlist
  include DB::Serializable

  property title : String
  property id : String
  property author : String
  property author_thumbnail : String
  property ucid : String
  property description : String
  property description_html : String
  property video_count : Int32
  property views : Int64
  property updated : Time
  property thumbnail : String?

  def to_json(offset, locale, json : JSON::Builder, continuation : String? = nil)
    json.object do
      json.field "type", "playlist"
      json.field "title", self.title
      json.field "playlistId", self.id
      json.field "playlistThumbnail", self.thumbnail

      json.field "author", self.author
      json.field "authorId", self.ucid
      json.field "authorUrl", "/channel/#{self.ucid}"

      json.field "authorThumbnails" do
        json.array do
          qualities = {32, 48, 76, 100, 176, 512}

          qualities.each do |quality|
            json.object do
              json.field "url", self.author_thumbnail.not_nil!.gsub(/=\d+/, "=s#{quality}")
              json.field "width", quality
              json.field "height", quality
            end
          end
        end
      end

      json.field "description", self.description
      json.field "descriptionHtml", self.description_html
      json.field "videoCount", self.video_count

      json.field "viewCount", self.views
      json.field "updated", self.updated.to_unix
      json.field "isListed", self.privacy.public?

      json.field "videos" do
        json.array do
          videos = get_playlist_videos(PG_DB, self, offset: offset, locale: locale, continuation: continuation)
          videos.each_with_index do |video, index|
            video.to_json(locale, json)
          end
        end
      end
    end
  end

  def to_json(offset, locale, json : JSON::Builder? = nil, continuation : String? = nil)
    if json
      to_json(offset, locale, json, continuation: continuation)
    else
      JSON.build do |json|
        to_json(offset, locale, json, continuation: continuation)
      end
    end
  end

  def privacy
    PlaylistPrivacy::Public
  end
end

enum PlaylistPrivacy
  Public   = 0
  Unlisted = 1
  Private  = 2
end

struct InvidiousPlaylist
  include DB::Serializable

  property title : String
  property id : String
  property author : String
  property description : String = ""
  property video_count : Int32
  property created : Time
  property updated : Time

  @[DB::Field(converter: InvidiousPlaylist::PlaylistPrivacyConverter)]
  property privacy : PlaylistPrivacy = PlaylistPrivacy::Private
  property index : Array(Int64)

  @[DB::Field(ignore: true)]
  property thumbnail_id : String?

  module PlaylistPrivacyConverter
    def self.from_rs(rs)
      return PlaylistPrivacy.parse(String.new(rs.read(Slice(UInt8))))
    end
  end

  def to_json(offset, locale, json : JSON::Builder, continuation : String? = nil)
    json.object do
      json.field "type", "invidiousPlaylist"
      json.field "title", self.title
      json.field "playlistId", self.id

      json.field "author", self.author
      json.field "authorId", self.ucid
      json.field "authorUrl", nil
      json.field "authorThumbnails", [] of String

      json.field "description", html_to_content(self.description_html)
      json.field "descriptionHtml", self.description_html
      json.field "videoCount", self.video_count

      json.field "viewCount", self.views
      json.field "updated", self.updated.to_unix
      json.field "isListed", self.privacy.public?

      json.field "videos" do
        json.array do
          if !offset || offset == 0
            index = PG_DB.query_one?("SELECT index FROM playlist_videos WHERE plid = $1 AND id = $2 LIMIT 1", self.id, continuation, as: Int64)
            offset = self.index.index(index) || 0
          end

          videos = get_playlist_videos(PG_DB, self, offset: offset, locale: locale, continuation: continuation)
          videos.each_with_index do |video, index|
            video.to_json(locale, json, offset + index)
          end
        end
      end
    end
  end

  def to_json(offset, locale, json : JSON::Builder? = nil, continuation : String? = nil)
    if json
      to_json(offset, locale, json, continuation: continuation)
    else
      JSON.build do |json|
        to_json(offset, locale, json, continuation: continuation)
      end
    end
  end

  def thumbnail
    @thumbnail_id ||= PG_DB.query_one?("SELECT id FROM playlist_videos WHERE plid = $1 ORDER BY array_position($2, index) LIMIT 1", self.id, self.index, as: String) || "-----------"
    "/vi/#{@thumbnail_id}/mqdefault.jpg"
  end

  def author_thumbnail
    nil
  end

  def ucid
    nil
  end

  def views
    0_i64
  end

  def description_html
    HTML.escape(self.description).gsub("\n", "<br>")
  end
end

def create_playlist(db, title, privacy, user)
  plid = "IVPL#{Random::Secure.urlsafe_base64(24)[0, 31]}"

  playlist = InvidiousPlaylist.new({
    title:       title.byte_slice(0, 150),
    id:          plid,
    author:      user.email,
    description: "", # Max 5000 characters
    video_count: 0,
    created:     Time.utc,
    updated:     Time.utc,
    privacy:     privacy,
    index:       [] of Int64,
  })

  playlist_array = playlist.to_a
  args = arg_array(playlist_array)

  db.exec("INSERT INTO playlists VALUES (#{args})", args: playlist_array)

  return playlist
end

def subscribe_playlist(db, user, playlist)
  playlist = InvidiousPlaylist.new({
    title:       playlist.title.byte_slice(0, 150),
    id:          playlist.id,
    author:      user.email,
    description: "", # Max 5000 characters
    video_count: playlist.video_count,
    created:     Time.utc,
    updated:     playlist.updated,
    privacy:     PlaylistPrivacy::Private,
    index:       [] of Int64,
  })

  playlist_array = playlist.to_a
  args = arg_array(playlist_array)

  db.exec("INSERT INTO playlists VALUES (#{args})", args: playlist_array)

  return playlist
end

def produce_playlist_continuation(id, index)
  if id.starts_with? "UC"
    id = "UU" + id.lchop("UC")
  end
  plid = "VL" + id

  # Emulate a "request counter" increment, to make perfectly valid
  # ctokens, even if at the time of writing, it's ignored by youtube.
  request_count = (index / 100).to_i64 || 1_i64

  data = {"1:varint" => index.to_i64}
    .try { |i| Protodec::Any.cast_json(i) }
    .try { |i| Protodec::Any.from_json(i) }
    .try { |i| Base64.urlsafe_encode(i, padding: false) }

  data_wrapper = {"1:varint" => request_count, "15:string" => "PT:#{data}"}
    .try { |i| Protodec::Any.cast_json(i) }
    .try { |i| Protodec::Any.from_json(i) }
    .try { |i| Base64.urlsafe_encode(i) }
    .try { |i| URI.encode_www_form(i) }

  object = {
    "80226972:embedded" => {
      "2:string"  => plid,
      "3:string"  => data_wrapper,
      "35:string" => id,
    },
  }

  continuation = object.try { |i| Protodec::Any.cast_json(object) }
    .try { |i| Protodec::Any.from_json(i) }
    .try { |i| Base64.urlsafe_encode(i) }
    .try { |i| URI.encode_www_form(i) }

  return continuation
end

def get_playlist(db, plid, locale, refresh = true, force_refresh = false)
  if plid.starts_with? "IV"
    if playlist = db.query_one?("SELECT * FROM playlists WHERE id = $1", plid, as: InvidiousPlaylist)
      return playlist
    else
      raise InfoException.new("Playlist does not exist.")
    end
  else
    return fetch_playlist(plid, locale)
  end
end

def fetch_playlist(plid, locale)
  if plid.starts_with? "UC"
    plid = "UU#{plid.lchop("UC")}"
  end

  initial_data = YoutubeAPI.browse("VL" + plid, params: "")

  playlist_sidebar_renderer = initial_data["sidebar"]?.try &.["playlistSidebarRenderer"]?.try &.["items"]?
  raise InfoException.new("Could not extract playlistSidebarRenderer.") if !playlist_sidebar_renderer

  playlist_info = playlist_sidebar_renderer[0]["playlistSidebarPrimaryInfoRenderer"]?
  raise InfoException.new("Could not extract playlist info") if !playlist_info

  title = playlist_info["title"]?.try &.["runs"][0]?.try &.["text"]?.try &.as_s || ""

  desc_item = playlist_info["description"]?

  description_txt = desc_item.try &.["runs"]?.try &.as_a
    .map(&.["text"].as_s).join("") || desc_item.try &.["simpleText"]?.try &.as_s || ""

  description_html = desc_item.try &.["runs"]?.try &.as_a
    .try { |run| content_to_comment_html(run).try &.to_s } || "<p></p>"

  thumbnail = playlist_info["thumbnailRenderer"]?.try &.["playlistVideoThumbnailRenderer"]?
    .try &.["thumbnail"]["thumbnails"][0]["url"]?.try &.as_s

  views = 0_i64
  updated = Time.utc
  video_count = 0
  playlist_info["stats"]?.try &.as_a.each do |stat|
    text = stat["runs"]?.try &.as_a.map(&.["text"].as_s).join("") || stat["simpleText"]?.try &.as_s
    next if !text

    if text.includes? "video"
      video_count = text.gsub(/\D/, "").to_i? || 0
    elsif text.includes? "view"
      views = text.gsub(/\D/, "").to_i64? || 0_i64
    else
      updated = decode_date(text.lchop("Last updated on ").lchop("Updated "))
    end
  end

  if playlist_sidebar_renderer.size < 2
    author = ""
    author_thumbnail = ""
    ucid = ""
  else
    author_info = playlist_sidebar_renderer[1]["playlistSidebarSecondaryInfoRenderer"]?.try &.["videoOwner"]["videoOwnerRenderer"]?
    raise InfoException.new("Could not extract author info") if !author_info

    author = author_info["title"]["runs"][0]["text"]?.try &.as_s || ""
    author_thumbnail = author_info["thumbnail"]["thumbnails"][0]["url"]?.try &.as_s || ""
    ucid = author_info["title"]["runs"][0]["navigationEndpoint"]["browseEndpoint"]["browseId"]?.try &.as_s || ""
  end

  return Playlist.new({
    title:            title,
    id:               plid,
    author:           author,
    author_thumbnail: author_thumbnail,
    ucid:             ucid,
    description:      description_txt,
    description_html: description_html,
    video_count:      video_count,
    views:            views,
    updated:          updated,
    thumbnail:        thumbnail,
  })
end

def get_playlist_videos(db, playlist, offset, locale = nil, continuation = nil)
  # Show empy playlist if requested page is out of range
  # (e.g, when a new playlist has been created, offset will be negative)
  if offset >= playlist.video_count || offset < 0
    return [] of PlaylistVideo
  end

  if playlist.is_a? InvidiousPlaylist
    db.query_all("SELECT * FROM playlist_videos WHERE plid = $1 ORDER BY array_position($2, index) LIMIT 100 OFFSET $3",
      playlist.id, playlist.index, offset, as: PlaylistVideo)
  else
    videos = [] of PlaylistVideo

    original_offset = offset
    until videos.size >= 100 || videos.size == playlist.video_count || offset >= playlist.video_count
      if offset >= 100
        # Normalize offset to match youtube's behavior (100 videos chunck per request)
        normalized_offset = (offset / 100).to_i64 * 100_i64
        ctoken = produce_playlist_continuation(playlist.id, normalized_offset)
        initial_data = request_youtube_api_browse(ctoken)
      else
        initial_data = request_youtube_api_browse("VL" + playlist.id, params: "")
      end

      videos += extract_playlist_videos(initial_data)

      if continuation
        until videos[0].id == continuation
          videos.shift
          if videos.size == 0
            break
          end
        end
      else
        until videos[0].index == original_offset
          videos.shift
          if videos.size == 0
            break
          end
        end
      end

      if videos.size > 0 && offset == 0
        offset = videos[0].index
      end

      offset += 100
    end

    return videos
  end
end

def extract_playlist_videos(initial_data : Hash(String, JSON::Any))
  videos = [] of PlaylistVideo

  if initial_data["contents"]?
    tabs = initial_data["contents"]["twoColumnBrowseResultsRenderer"]["tabs"]
    tabs_renderer = tabs.as_a.select(&.["tabRenderer"]["selected"]?.try &.as_bool)[0]["tabRenderer"]

    # Watch out the two versions, with and without "s"
    if tabs_renderer["contents"]? || tabs_renderer["content"]?
      # Initial playlist data
      tabs_contents = tabs_renderer.["contents"]? || tabs_renderer.["content"]

      list_renderer = tabs_contents.["sectionListRenderer"]["contents"][0]
      item_renderer = list_renderer.["itemSectionRenderer"]["contents"][0]
      contents = item_renderer.["playlistVideoListRenderer"]["contents"].as_a
    else
      # Continuation data
      contents = initial_data["onResponseReceivedActions"][0]?
        .try &.["appendContinuationItemsAction"]["continuationItems"].as_a
    end
  else
    contents = initial_data["response"]?.try &.["continuationContents"]["playlistVideoListContinuation"]["contents"].as_a
  end

  contents.try &.each do |item|
    if i = item["playlistVideoRenderer"]?
      video_id = i["navigationEndpoint"]["watchEndpoint"]["videoId"].as_s
      plid = i["navigationEndpoint"]["watchEndpoint"]["playlistId"].as_s
      index = i["navigationEndpoint"]["watchEndpoint"]["index"].as_i64

      thumbnail = i["thumbnail"]["thumbnails"][0]["url"].as_s
      title = i["title"].try { |t| t["simpleText"]? || t["runs"]?.try &.[0]["text"]? }.try &.as_s || ""
      author = i["shortBylineText"]?.try &.["runs"][0]["text"].as_s || ""
      ucid = i["shortBylineText"]?.try &.["runs"][0]["navigationEndpoint"]["browseEndpoint"]["browseId"].as_s || ""
      length_seconds = i["lengthSeconds"]?.try &.as_s.to_i
      live = false

      if !length_seconds
        live = true
        length_seconds = 0
      end

      videos << PlaylistVideo.new({
        title:          title,
        id:             video_id,
        author:         author,
        ucid:           ucid,
        length_seconds: length_seconds,
        published:      Time.utc,
        plid:           plid,
        live_now:       live,
        index:          index,
      })
    end
  end

  return videos
end

def template_playlist(playlist)
  html = <<-END_HTML
  <h3>
    <a href="/playlist?list=#{playlist["playlistId"]}">
      #{playlist["title"]}
    </a>
  </h3>
  <div class="pure-menu pure-menu-scrollable playlist-restricted">
    <ol class="pure-menu-list">
  END_HTML

  playlist["videos"].as_a.each do |video|
    html += <<-END_HTML
      <li class="pure-menu-item" id="#{video["videoId"]}">
        <a href="/watch?v=#{video["videoId"]}&list=#{playlist["playlistId"]}&index=#{video["index"]}">
          <div class="thumbnail">
              <img class="thumbnail" src="/vi/#{video["videoId"]}/mqdefault.jpg">
              <p class="length">#{recode_length_seconds(video["lengthSeconds"].as_i)}</p>
          </div>
          <p style="width:100%">#{video["title"]}</p>
          <p>
            <b style="width:100%">#{video["author"]}</b>
          </p>
        </a>
      </li>
    END_HTML
  end

  html += <<-END_HTML
    </ol>
  </div>
  <hr>
  END_HTML

  html
end
