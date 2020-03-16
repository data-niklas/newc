require "option_parser"
require "readability"
require "http/client"
require "path"
require "json"
require "xml"
require "file"
require "dir"
require "file_utils"
require "rss"

module RSS
  extend self
  class Item
    JSON.mapping({
        "title"=>String,
        "link"=>String,
        "pubDate"=>String,
        "comments"=>String,
        "description"=>String,
        "guid"=>String,
        "author"=>String,
        "category"=>String
    });
  end
end

class Newc

    @settings_dir : Path
    @settings_file : Path
    @cache_file : Path
    @settings : JSON::Any
    @@html_template : String = <<-TEMPLATE
   <!DOCTYPE html>
   <html>
   <head>
     <meta content="text/html; charset=UTF-8" http-equiv="content-type" />
     <style>
       :root{
         --background-color: {{{BackgroundColor}}};
         --color: {{{Color}}};
         --accent: {{{Accent}}};
         --font: "Lucida Sans Unicode", "Lucida Grande", sans-serif;
       }
       img{
           max-width: 100%;
           height: auto;
       }
        blockquote{
          border-inline-start: 4px solid var(--accent);
          padding-inline-start: 20px;
        }
        body{
          display: flex;
          flex-direction: column;
          align-items: center;
          background-color: var(--background-color);
          color: var(--color);

          font-family: var(--font);
        }
        #content{
          width: 35%;
        }
        #title{
          font-size: 1.8em;
          line-height: 1.40em;
          margin-bottom: 0.5em;
          margin-top: 0.8em;
        }
        #page{
          margin-top: 2em;
          line-height: 1.5em;
          font-size: large;
        }
        #author{
          line-height: 2em;
          max-width: max-content;
        }
        .line{
          width: 100%;
          height: 1px;
          background-color: var(--color);
        }
    </style>
   </head>  
   <body>
      <div id="content">
        <div id="author">
          {{{Author}}}
          <div class="line"></div>
        </div>
        <h1 id="title">
          {{{Title}}}
        </h1>
        <div class="line" ></div>
        <div id="page">
          {{{Page}}}  
        </div>
      </div>
   </body>   
   </html>
TEMPLATE


    def initialize(settings_dir : Path)
        #@@settings_dir = (settings_dir.as(Path) || Path["~/.local/share/newc"].expand(home: true)).as(Path)
        @settings_dir = settings_dir
        @settings_file = @settings_dir / Path["settings.json"]
        @cache_file = @settings_dir / Path["cache.json"]
        @settings = JSON.parse("{}")

        if (!File.exists? @settings_dir)
            FileUtils.mkdir_p(@settings_dir.to_s)
        end

        if (!File.exists? @settings_file)
            File.write(@settings_file.to_s,
            "{
                \"expire_time\" : 10,
                \"last_refresh\" : -1,
                \"feeds\" : []
            }")
        end
        if (!File.exists? @cache_file)
            File.write(@cache_file.to_s,"{}")
        end

        @settings = self.load_settings
    
    end
    

    def load_settings()
        JSON.parse(File.read(@settings_file))
    end


    def expired?()
        diff_seconds = (Time.utc.to_unix - @settings["last_refresh"].as_i)
        diff_seconds > @settings["expire_time"].as_i * 60
    end


    def load_rss(force)
        feed_items = [] of RSS::Item

        # Not expired?
        if !force && !self.expired?
            # Loaded from cache
            feed_items = Array(RSS::Item).from_json(File.read(@cache_file))
        else
            channel = Channel(Nil).new

            # Gets the RSS feeds in parallel
            feeds = @settings["feeds"].as_a
            feeds.each do |feed|
                spawn do
                    rss_feed = RSS.parse feed.to_s
                    feed_items = feed_items + rss_feed.items

                    channel.send(nil)
                end
            end
            # Waits for all feeds to be done
            feeds.size.times do 
                channel.receive
            end

            # RSS items sorted by date
            feed_items.sort do |a,b|
                unix_a = Time.parse(a.pubDate.gsub("GMT","+0000"),"%a, %d %b %Y %T %z", Time::Location::UTC).to_unix
                unix_b = Time.parse(b.pubDate.gsub("GMT","+0000"),"%a, %d %b %Y %T %z", Time::Location::UTC).to_unix
                unix_a < unix_b ? -1 : (unix_a == unix_b ? 0 : 1)
            end

            # Saved to cache
            File.write(@cache_file, feed_items.to_json)
            changed_settings = {
                "expire_time" => @settings["expire_time"],
                "last_refresh" => Time.utc.to_unix,
                "feeds" => @settings["feeds"]
            }
            self.save_settings(changed_settings)

        end

        feed_items
    end


    def save_settings(some_hash)
        File.write(@settings_file, some_hash.to_json)
    end

    # Adds a rss feed to the settings
    def add_feed(feed)
        feeds = @settings["feeds"].as_a
        feeds << JSON::Any.new(feed)
        changed_settings = {
            "expire_time" => @settings["expire_time"],
            "last_refresh" => -1,
            "feeds" => feeds
        }
        self.save_settings(changed_settings)
    end


    # Delete a rss feed from the settings
    def remove_feed(feed)
        feeds = @settings["feeds"].as_a
        feeds.delete(JSON::Any.new(feed))
        changed_settings = {
            "expire_time" => @settings["expire_time"],
            "last_refresh" => -1,
            "feeds" => feeds
        }
        self.save_settings(changed_settings)
    end


    def to_xml(result)
        XML.build(indent: "  ") do |xml|
            xml.element("feed") do

                result.each do |item|
                    xml.element("item") do
                        xml.element("title"){xml.text item.title}
                        xml.element("link"){xml.text item.link}
                        xml.element("pubDate"){xml.text item.pubDate}
                        xml.element("description"){xml.text item.description}
                        xml.element("comments"){xml.text item.comments}
                        xml.element("guid"){xml.text item.guid}
                        xml.element("author"){xml.text item.author}
                        xml.element("category"){xml.text item.category}
                    end
                end

            end
        end
    end

    def to_readable(result)
        String.build do |str|
            result.each do |item|
                str << "\n"
                str << item.title + "\t\t" + item.pubDate
                str << "\n"
                str << item.link + "\t" + item.author + "\t" + item.category
                str << "\n----------------------------\n"
                str << item.description.gsub(". ", ".\n")
                str << "\n\n"
            end
        end
    end


    # Print a rss feed
    # Force: if all of the feeds should be reloaded or taken from the cache (if they did not expire)
    def print_feed(format, force)
        
        result = self.load_rss(force)
        if format == "json"
            puts result.to_json

        elsif format == "xml"
            xml = self.to_xml(result)
            puts xml

        elsif format == "readable"
            readable = self.to_readable(result)
            puts readable
        end
    end

    # Takes an url and returns a more readable version of the webpage
    # Either in xml format, json format, or as a html page (or readable to the command line)
    # HTML theme (light, dark, sepia) can also be set
    # Uses the readability library
    def print_readable(format, url, theme)
        response = HTTP::Client.get url

        if format == "readable"
            options = Readability::Options.new()
        else
            options = Readability::Options.new(
                tags: %w[article p span div document b strong em h1 h2 h3 h4 aside],
                remove_empty_nodes: true,
                remove_unlikely_candidates: true,
                weight_classes: true,
                clean_conditionally: true
            )
        end
        document = Readability::Document.new(response.body,options)
    
        # Sets all of the important information
        # Title, author and content of the page / article
        res = {
            "title" => document.title || "",
            "author" => document.author || "",
            "content" => document.content || ""
        }

        if format == "json"
            puts res.to_json
        elsif format == "xml"
            # XML Builder
            xml = XML.build(indent: "  ") do |xml|
                xml.element("article") do
                    xml.element("title"){xml.text res["title"]}
                    xml.element("author"){xml.text res["author"]}
                    xml.element("content"){xml.text res["content"]}
                end
            end
            puts xml
        elsif format == "page"
            # Fill the html template
            filled_template = @@html_template.gsub("{{{Author}}}", res["author"]).gsub("{{{Title}}}", res["title"]).gsub("{{{Page}}}", res["content"])
            case theme
                when "light"
                    background_color = "#FEFEFE"
                    color = "#232323"
                    accent = "#424242"
                when "dark"
                    background_color = "#232323"
                    color = "#FEFEFE"
                    accent = "#BABABA"
                when "sepia"
                    background_color = "#FFE0B2"
                    color = "#232323"
                    accent = "#424242"
                else 
                    puts "Theme needs to be one of: 'light', 'dark' or 'sepia'"
                    exit
            end
            puts filled_template.gsub("{{{BackgroundColor}}}", background_color).gsub("{{{Color}}}", color).gsub("{{{Accent}}}", accent)
        elsif format == "readable"
            # Just print to command line
            puts res["title"], res["author"], "----------------------------", res["content"].split(/\.(?=\S{3,})/).join(".\n\n")
        end
    end

    # Print all settings
    def print_settings()
        puts @settings.to_json
    end

    # Print a specific setting to the command line
    def print_setting(setting)
        if @settings.as_h.has_key?(setting)
            puts @settings[setting]
        else
            puts "Settings does not exist"
        end
    end
end


TAB = "    "

output_format = "json"
settings_dir = Path["~/.local/share/newc"].expand(home: true)
force = false
newc : Newc
page_theme = ""

OptionParser.parse do |parser|
    # Help to be shown
    show_help = ->{
        puts parser,"",""
        puts "Commands:","","#{TAB}feed\t\t\tPrints the news feed to the console in a given output format","","#{TAB}#{TAB}Default output format: json","#{TAB}#{TAB}Example: newc -x feed","",""
        puts "#{TAB}readability\t\t\tPrints a more readable version of a website to the console in a given output format","","#{TAB}#{TAB}Arguments:","#{TAB}#{TAB}#{TAB}1) url of the website","#{TAB}#{TAB}Default output format: json", "#{TAB}#{TAB}Example: newc readability https://www.testwebsite.com/","",""
        puts "#{TAB}list\t\t\tLists settings","","#{TAB}#{TAB}Arguments:","#{TAB}#{TAB}#{TAB}1) the name of the setting","#{TAB}#{TAB}If setting name is omitted, all settings are shown", "#{TAB}#{TAB}Example: newc list feeds","",""
        puts "#{TAB}add\t\t\tAdd feed","","#{TAB}#{TAB}Arguments:","#{TAB}#{TAB}#{TAB}1) the url of the feed","#{TAB}#{TAB}Example: newc add http://feeds.bbci.co.uk/news/technology/rss.xml","",""
        puts "#{TAB}remove\t\t\Remove feed","","#{TAB}#{TAB}Arguments:","#{TAB}#{TAB}#{TAB}1) the url of the feed","#{TAB}#{TAB}Example: newc remove http://feeds.bbci.co.uk/news/technology/rss.xml","",""
    }

    parser.on "-c", "--config=DIR", "Config directory" do |dir|
        settings_dir = Path[dir].expand(home: true).normalize()
    end


    parser.on "-h", "--help", "Shows the help" do
        show_help.call
        exit
    end

    parser.on "-j", "--json", "JSON output format" do
        output_format = "json"
    end

    parser.on "-x", "--xml", "XML output format" do
        output_format = "xml"
    end

    parser.on "-p", "--page=THEME", "Page (HTML) output format" do |theme|
        output_format = "page"
        page_theme = theme || "light"
    end

    parser.on "-r", "--readable", "Readable output format" do
        output_format = "readable"
    end

    parser.on "-f", "--force", "Force feed updates" do
        force = true
    end

    parser.unknown_args do |args_arr|
        newc = Newc.new(settings_dir)
        if args_arr.size > 0
            case args_arr[0]
                when "feed"
                    newc.print_feed(output_format, force)
                when "readability"
                    if args_arr.size == 2
                        newc.print_readable(output_format, args_arr[1], page_theme)
                    else
                        puts "Needs one URL as a second parameter"
                        show_help.call
                        exit
                    end
                when "list"
                    if args_arr.size == 1
                        newc.print_settings()
                    else
                        newc.print_setting(args_arr[1])
                    end
                when "add"
                    if args_arr.size != 2
                        puts "You must provide an url to a rss feed"
                        show_help.call
                    else
                        newc.add_feed(args_arr[1])
                    end

                when "remove"
                    if args_arr.size != 2
                        puts "You must provide an url to a rss feed"
                        show_help.call
                    else
                        newc.remove_feed(args_arr[1])
                    end
                else
                    newc.print_feed(output_format, force)

            end
        else
            puts "No command was specified: "
            show_help.call
            exit
        end
    end
end