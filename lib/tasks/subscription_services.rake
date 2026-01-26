namespace :subscription_services do
  desc "Cache all subscription service icons locally"
  task cache_icons: :environment do
    services = SubscriptionService.left_joins(:icon_attachment).where(active_storage_attachments: { id: nil })
    total = services.count

    puts "Caching #{total} icons..."
    services.find_each.with_index do |service, i|
      CacheSubscriptionIconJob.perform_later(service)
      print "\rQueued #{i + 1}/#{total}"
    end
    puts "\nDone! Jobs queued for processing."
  end

  desc "Seed subscription services database with popular services"
  task seed: :environment do
    puts "Seeding subscription services..."

    services = [
      # ============ STREAMING VIDEO (60+) ============
      { name: "Netflix", slug: "netflix", domain: "netflix.com", category: "streaming", color: "#E50914" },
      { name: "Disney+", slug: "disney-plus", domain: "disneyplus.com", category: "streaming", color: "#113CCF" },
      { name: "Hulu", slug: "hulu", domain: "hulu.com", category: "streaming", color: "#1CE783" },
      { name: "Amazon Prime Video", slug: "amazon-prime-video", domain: "primevideo.com", category: "streaming", color: "#00A8E1" },
      { name: "HBO Max", slug: "hbo-max", domain: "max.com", category: "streaming", color: "#5822B4" },
      { name: "Max", slug: "max", domain: "max.com", category: "streaming", color: "#002BE7" },
      { name: "Apple TV+", slug: "apple-tv-plus", domain: "tv.apple.com", category: "streaming", color: "#000000" },
      { name: "Peacock", slug: "peacock", domain: "peacocktv.com", category: "streaming", color: "#000000" },
      { name: "Paramount+", slug: "paramount-plus", domain: "paramountplus.com", category: "streaming", color: "#0064FF" },
      { name: "YouTube Premium", slug: "youtube-premium", domain: "youtube.com", category: "streaming", color: "#FF0000" },
      { name: "YouTube TV", slug: "youtube-tv", domain: "tv.youtube.com", category: "streaming", color: "#FF0000" },
      { name: "Crunchyroll", slug: "crunchyroll", domain: "crunchyroll.com", category: "streaming", color: "#F47521" },
      { name: "Funimation", slug: "funimation", domain: "funimation.com", category: "streaming", color: "#5B0BB5" },
      { name: "Discovery+", slug: "discovery-plus", domain: "discoveryplus.com", category: "streaming", color: "#0033FF" },
      { name: "ESPN+", slug: "espn-plus", domain: "espn.com", category: "streaming", color: "#FF0000" },
      { name: "Showtime", slug: "showtime", domain: "showtime.com", category: "streaming", color: "#FF0000" },
      { name: "Starz", slug: "starz", domain: "starz.com", category: "streaming", color: "#000000" },
      { name: "MGM+", slug: "mgm-plus", domain: "mgmplus.com", category: "streaming", color: "#C4A000" },
      { name: "AMC+", slug: "amc-plus", domain: "amcplus.com", category: "streaming", color: "#000000" },
      { name: "BritBox", slug: "britbox", domain: "britbox.com", category: "streaming", color: "#C4171D" },
      { name: "Acorn TV", slug: "acorn-tv", domain: "acorn.tv", category: "streaming", color: "#6B8E23" },
      { name: "Shudder", slug: "shudder", domain: "shudder.com", category: "streaming", color: "#EF2D23" },
      { name: "Curiosity Stream", slug: "curiosity-stream", domain: "curiositystream.com", category: "streaming", color: "#2196F3" },
      { name: "Criterion Channel", slug: "criterion-channel", domain: "criterionchannel.com", category: "streaming", color: "#000000" },
      { name: "MUBI", slug: "mubi", domain: "mubi.com", category: "streaming", color: "#001489" },
      { name: "Kanopy", slug: "kanopy", domain: "kanopy.com", category: "streaming", color: "#E31837" },
      { name: "Plex", slug: "plex", domain: "plex.tv", category: "streaming", color: "#E5A00D" },
      { name: "Viki", slug: "viki", domain: "viki.com", category: "streaming", color: "#1E88E5" },
      { name: "Tubi", slug: "tubi", domain: "tubitv.com", category: "streaming", color: "#FA382F" },
      { name: "Pluto TV", slug: "pluto-tv", domain: "pluto.tv", category: "streaming", color: "#000000" },
      { name: "fuboTV", slug: "fubotv", domain: "fubo.tv", category: "streaming", color: "#FF6B00" },
      { name: "Sling TV", slug: "sling-tv", domain: "sling.com", category: "streaming", color: "#2196F3" },
      { name: "Philo", slug: "philo", domain: "philo.com", category: "streaming", color: "#0066FF" },
      { name: "DIRECTV STREAM", slug: "directv-stream", domain: "directv.com", category: "streaming", color: "#00A3E0" },
      { name: "Vudu", slug: "vudu", domain: "vudu.com", category: "streaming", color: "#3399FF" },
      { name: "Rakuten Viki", slug: "rakuten-viki", domain: "viki.com", category: "streaming", color: "#1E88E5" },
      { name: "Tencent Video", slug: "tencent-video", domain: "v.qq.com", category: "streaming", color: "#FF6600" },
      { name: "iQIYI", slug: "iqiyi", domain: "iqiyi.com", category: "streaming", color: "#00BE06" },
      { name: "Hotstar", slug: "hotstar", domain: "hotstar.com", category: "streaming", color: "#1F2937" },
      { name: "Stan", slug: "stan", domain: "stan.com.au", category: "streaming", color: "#0066FF" },
      { name: "Crave", slug: "crave", domain: "crave.ca", category: "streaming", color: "#00A0D6" },
      { name: "NOW TV", slug: "now-tv", domain: "nowtv.com", category: "streaming", color: "#2DC84D" },
      { name: "Sky", slug: "sky", domain: "sky.com", category: "streaming", color: "#0072C9" },
      { name: "hayu", slug: "hayu", domain: "hayu.com", category: "streaming", color: "#FF1493" },
      { name: "Hallmark Movies Now", slug: "hallmark-movies-now", domain: "hallmarkmovies.com", category: "streaming", color: "#B91C1C" },
      { name: "BET+", slug: "bet-plus", domain: "bet.com", category: "streaming", color: "#E50914" },
      { name: "Boomerang", slug: "boomerang", domain: "boomerang.com", category: "streaming", color: "#FFD700" },
      { name: "Cartoon Network", slug: "cartoon-network", domain: "cartoonnetwork.com", category: "streaming", color: "#000000" },
      { name: "Noggin", slug: "noggin", domain: "noggin.com", category: "streaming", color: "#FF6600" },
      { name: "PBS Kids", slug: "pbs-kids", domain: "pbskids.org", category: "streaming", color: "#009639" },

      # ============ MUSIC (25+) ============
      { name: "Spotify", slug: "spotify", domain: "spotify.com", category: "music", color: "#1DB954" },
      { name: "Apple Music", slug: "apple-music", domain: "music.apple.com", category: "music", color: "#FA243C" },
      { name: "Amazon Music", slug: "amazon-music", domain: "music.amazon.com", category: "music", color: "#00A8E1" },
      { name: "YouTube Music", slug: "youtube-music", domain: "music.youtube.com", category: "music", color: "#FF0000" },
      { name: "Tidal", slug: "tidal", domain: "tidal.com", category: "music", color: "#000000" },
      { name: "Deezer", slug: "deezer", domain: "deezer.com", category: "music", color: "#FEAA2D" },
      { name: "Pandora", slug: "pandora", domain: "pandora.com", category: "music", color: "#3668FF" },
      { name: "SoundCloud", slug: "soundcloud", domain: "soundcloud.com", category: "music", color: "#FF5500" },
      { name: "Audible", slug: "audible", domain: "audible.com", category: "music", color: "#F8991C" },
      { name: "Audiobooks.com", slug: "audiobooks-com", domain: "audiobooks.com", category: "music", color: "#2196F3" },
      { name: "Scribd", slug: "scribd", domain: "scribd.com", category: "music", color: "#1A1A2E" },
      { name: "Napster", slug: "napster", domain: "napster.com", category: "music", color: "#000000" },
      { name: "Qobuz", slug: "qobuz", domain: "qobuz.com", category: "music", color: "#4285F4" },
      { name: "Bandcamp", slug: "bandcamp", domain: "bandcamp.com", category: "music", color: "#629AA9" },
      { name: "iHeartRadio", slug: "iheartradio", domain: "iheart.com", category: "music", color: "#C6002B" },
      { name: "TuneIn", slug: "tunein", domain: "tunein.com", category: "music", color: "#14D8CC" },
      { name: "Stitcher", slug: "stitcher", domain: "stitcher.com", category: "music", color: "#000000" },
      { name: "Pocket Casts", slug: "pocket-casts", domain: "pocketcasts.com", category: "music", color: "#F43E37" },
      { name: "Overcast", slug: "overcast", domain: "overcast.fm", category: "music", color: "#FC7E0F" },
      { name: "Castro", slug: "castro", domain: "castro.fm", category: "music", color: "#00B265" },
      { name: "Luminary", slug: "luminary", domain: "luminarypodcasts.com", category: "music", color: "#5A31F4" },
      { name: "Wondery+", slug: "wondery-plus", domain: "wondery.com", category: "music", color: "#232F3E" },
      { name: "Calm", slug: "calm", domain: "calm.com", category: "music", color: "#4AADE9" },
      { name: "Headspace", slug: "headspace", domain: "headspace.com", category: "music", color: "#F47D31" },

      # ============ SOFTWARE & PRODUCTIVITY (70+) ============
      { name: "Microsoft 365", slug: "microsoft-365", domain: "microsoft.com", category: "software", color: "#0078D4" },
      { name: "Google Workspace", slug: "google-workspace", domain: "workspace.google.com", category: "software", color: "#4285F4" },
      { name: "Adobe Creative Cloud", slug: "adobe-creative-cloud", domain: "adobe.com", category: "software", color: "#FF0000" },
      { name: "Notion", slug: "notion", domain: "notion.so", category: "software", color: "#000000" },
      { name: "Figma", slug: "figma", domain: "figma.com", category: "software", color: "#F24E1E" },
      { name: "Canva", slug: "canva", domain: "canva.com", category: "software", color: "#00C4CC" },
      { name: "Slack", slug: "slack", domain: "slack.com", category: "software", color: "#4A154B" },
      { name: "Zoom", slug: "zoom", domain: "zoom.us", category: "software", color: "#2D8CFF" },
      { name: "Dropbox", slug: "dropbox", domain: "dropbox.com", category: "software", color: "#0061FF" },
      { name: "Evernote", slug: "evernote", domain: "evernote.com", category: "software", color: "#00A82D" },
      { name: "Todoist", slug: "todoist", domain: "todoist.com", category: "software", color: "#E44332" },
      { name: "Asana", slug: "asana", domain: "asana.com", category: "software", color: "#F06A6A" },
      { name: "Monday.com", slug: "monday-com", domain: "monday.com", category: "software", color: "#FF3D57" },
      { name: "Trello", slug: "trello", domain: "trello.com", category: "software", color: "#0079BF" },
      { name: "ClickUp", slug: "clickup", domain: "clickup.com", category: "software", color: "#7B68EE" },
      { name: "Linear", slug: "linear", domain: "linear.app", category: "software", color: "#5E6AD2" },
      { name: "Airtable", slug: "airtable", domain: "airtable.com", category: "software", color: "#18BFFF" },
      { name: "Coda", slug: "coda", domain: "coda.io", category: "software", color: "#F46A54" },
      { name: "Roam Research", slug: "roam-research", domain: "roamresearch.com", category: "software", color: "#343A40" },
      { name: "Obsidian", slug: "obsidian", domain: "obsidian.md", category: "software", color: "#7C3AED" },
      { name: "Craft", slug: "craft", domain: "craft.do", category: "software", color: "#0066FF" },
      { name: "Bear", slug: "bear", domain: "bear.app", category: "software", color: "#D9534F" },
      { name: "Ulysses", slug: "ulysses", domain: "ulysses.app", category: "software", color: "#3670C4" },
      { name: "1Password", slug: "1password", domain: "1password.com", category: "software", color: "#0094F5" },
      { name: "LastPass", slug: "lastpass", domain: "lastpass.com", category: "software", color: "#D32D27" },
      { name: "Bitwarden", slug: "bitwarden", domain: "bitwarden.com", category: "software", color: "#175DDC" },
      { name: "Dashlane", slug: "dashlane", domain: "dashlane.com", category: "software", color: "#0E353D" },
      { name: "Keeper", slug: "keeper", domain: "keepersecurity.com", category: "software", color: "#0073CF" },
      { name: "NordPass", slug: "nordpass", domain: "nordpass.com", category: "software", color: "#4687FF" },
      { name: "Grammarly", slug: "grammarly", domain: "grammarly.com", category: "software", color: "#15C39A" },
      { name: "Mailchimp", slug: "mailchimp", domain: "mailchimp.com", category: "software", color: "#FFE01B" },
      { name: "ConvertKit", slug: "convertkit", domain: "convertkit.com", category: "software", color: "#FB6970" },
      { name: "Substack", slug: "substack", domain: "substack.com", category: "software", color: "#FF6719" },
      { name: "Beehiiv", slug: "beehiiv", domain: "beehiiv.com", category: "software", color: "#F2C94C" },
      { name: "Buffer", slug: "buffer", domain: "buffer.com", category: "software", color: "#231F20" },
      { name: "Hootsuite", slug: "hootsuite", domain: "hootsuite.com", category: "software", color: "#143059" },
      { name: "Sprout Social", slug: "sprout-social", domain: "sproutsocial.com", category: "software", color: "#59CB59" },
      { name: "Later", slug: "later", domain: "later.com", category: "software", color: "#FF5252" },
      { name: "HubSpot", slug: "hubspot", domain: "hubspot.com", category: "software", color: "#FF7A59" },
      { name: "Salesforce", slug: "salesforce", domain: "salesforce.com", category: "software", color: "#00A1E0" },
      { name: "Pipedrive", slug: "pipedrive", domain: "pipedrive.com", category: "software", color: "#017737" },
      { name: "Zendesk", slug: "zendesk", domain: "zendesk.com", category: "software", color: "#03363D" },
      { name: "Intercom", slug: "intercom", domain: "intercom.com", category: "software", color: "#6AFDEF" },
      { name: "Freshdesk", slug: "freshdesk", domain: "freshdesk.com", category: "software", color: "#25C16F" },
      { name: "Calendly", slug: "calendly", domain: "calendly.com", category: "software", color: "#006BFF" },
      { name: "Cal.com", slug: "cal-com", domain: "cal.com", category: "software", color: "#292929" },
      { name: "Loom", slug: "loom", domain: "loom.com", category: "software", color: "#625DF5" },
      { name: "Miro", slug: "miro", domain: "miro.com", category: "software", color: "#FFD02F" },
      { name: "Whimsical", slug: "whimsical", domain: "whimsical.com", category: "software", color: "#7856FF" },
      { name: "Mural", slug: "mural", domain: "mural.co", category: "software", color: "#FF4B4B" },
      { name: "FigJam", slug: "figjam", domain: "figma.com", category: "software", color: "#F24E1E" },
      { name: "Sketch", slug: "sketch", domain: "sketch.com", category: "software", color: "#F7B500" },
      { name: "InVision", slug: "invision", domain: "invisionapp.com", category: "software", color: "#FF3366" },
      { name: "Zeplin", slug: "zeplin", domain: "zeplin.io", category: "software", color: "#FDBD39" },
      { name: "Abstract", slug: "abstract", domain: "abstract.com", category: "software", color: "#191A1B" },
      { name: "Framer", slug: "framer", domain: "framer.com", category: "software", color: "#0055FF" },
      { name: "Webflow", slug: "webflow", domain: "webflow.com", category: "software", color: "#4353FF" },
      { name: "Squarespace", slug: "squarespace", domain: "squarespace.com", category: "software", color: "#000000" },
      { name: "Wix", slug: "wix", domain: "wix.com", category: "software", color: "#0C6EFC" },
      { name: "Shopify", slug: "shopify", domain: "shopify.com", category: "software", color: "#7AB55C" },
      { name: "BigCommerce", slug: "bigcommerce", domain: "bigcommerce.com", category: "software", color: "#121118" },
      { name: "WooCommerce", slug: "woocommerce", domain: "woocommerce.com", category: "software", color: "#96588A" },
      { name: "Gumroad", slug: "gumroad", domain: "gumroad.com", category: "software", color: "#FF90E8" },
      { name: "Patreon", slug: "patreon", domain: "patreon.com", category: "software", color: "#FF424D" },
      { name: "Ko-fi", slug: "ko-fi", domain: "ko-fi.com", category: "software", color: "#FF5E5B" },
      { name: "Buy Me a Coffee", slug: "buy-me-a-coffee", domain: "buymeacoffee.com", category: "software", color: "#FFDD00" },
      { name: "Memberful", slug: "memberful", domain: "memberful.com", category: "software", color: "#6772E5" },
      { name: "Superwhisper", slug: "superwhisper", domain: "superwhisper.com", category: "software", color: "#000000" },

      # ============ GAMING (25+) ============
      { name: "Xbox Game Pass", slug: "xbox-game-pass", domain: "xbox.com", category: "gaming", color: "#107C10" },
      { name: "PlayStation Plus", slug: "playstation-plus", domain: "playstation.com", category: "gaming", color: "#003791" },
      { name: "Nintendo Switch Online", slug: "nintendo-switch-online", domain: "nintendo.com", category: "gaming", color: "#E60012" },
      { name: "EA Play", slug: "ea-play", domain: "ea.com", category: "gaming", color: "#FF4747" },
      { name: "Ubisoft+", slug: "ubisoft-plus", domain: "ubisoft.com", category: "gaming", color: "#000000" },
      { name: "GeForce NOW", slug: "geforce-now", domain: "nvidia.com", category: "gaming", color: "#76B900" },
      { name: "Xbox Live Gold", slug: "xbox-live-gold", domain: "xbox.com", category: "gaming", color: "#107C10" },
      { name: "PlayStation Now", slug: "playstation-now", domain: "playstation.com", category: "gaming", color: "#003791" },
      { name: "Google Stadia", slug: "google-stadia", domain: "stadia.google.com", category: "gaming", color: "#CD2640" },
      { name: "Amazon Luna", slug: "amazon-luna", domain: "amazon.com", category: "gaming", color: "#9146FF" },
      { name: "Apple Arcade", slug: "apple-arcade", domain: "apple.com", category: "gaming", color: "#000000" },
      { name: "Google Play Pass", slug: "google-play-pass", domain: "play.google.com", category: "gaming", color: "#01875F" },
      { name: "Humble Choice", slug: "humble-choice", domain: "humblebundle.com", category: "gaming", color: "#CC2929" },
      { name: "Discord Nitro", slug: "discord-nitro", domain: "discord.com", category: "gaming", color: "#5865F2" },
      { name: "Twitch", slug: "twitch", domain: "twitch.tv", category: "gaming", color: "#9146FF" },
      { name: "World of Warcraft", slug: "world-of-warcraft", domain: "worldofwarcraft.com", category: "gaming", color: "#000000" },
      { name: "Final Fantasy XIV", slug: "final-fantasy-xiv", domain: "finalfantasyxiv.com", category: "gaming", color: "#1A1A1A" },
      { name: "Elder Scrolls Online", slug: "elder-scrolls-online", domain: "elderscrollsonline.com", category: "gaming", color: "#C9A227" },
      { name: "RuneScape", slug: "runescape", domain: "runescape.com", category: "gaming", color: "#D4AF37" },
      { name: "Eve Online", slug: "eve-online", domain: "eveonline.com", category: "gaming", color: "#000000" },
      { name: "Star Citizen", slug: "star-citizen", domain: "robertsspaceindustries.com", category: "gaming", color: "#1A1A1A" },
      { name: "Roblox Premium", slug: "roblox-premium", domain: "roblox.com", category: "gaming", color: "#E2231A" },
      { name: "Fortnite Crew", slug: "fortnite-crew", domain: "fortnite.com", category: "gaming", color: "#000000" },
      { name: "League of Legends", slug: "league-of-legends", domain: "leagueoflegends.com", category: "gaming", color: "#C89B3C" },

      # ============ NEWS & MEDIA (35+) ============
      { name: "The New York Times", slug: "new-york-times", domain: "nytimes.com", category: "news", color: "#000000" },
      { name: "The Washington Post", slug: "washington-post", domain: "washingtonpost.com", category: "news", color: "#000000" },
      { name: "The Wall Street Journal", slug: "wall-street-journal", domain: "wsj.com", category: "news", color: "#000000" },
      { name: "The Economist", slug: "economist", domain: "economist.com", category: "news", color: "#E3120B" },
      { name: "Financial Times", slug: "financial-times", domain: "ft.com", category: "news", color: "#FCD0B1" },
      { name: "Bloomberg", slug: "bloomberg", domain: "bloomberg.com", category: "news", color: "#000000" },
      { name: "The Atlantic", slug: "atlantic", domain: "theatlantic.com", category: "news", color: "#000000" },
      { name: "The New Yorker", slug: "new-yorker", domain: "newyorker.com", category: "news", color: "#000000" },
      { name: "Wired", slug: "wired", domain: "wired.com", category: "news", color: "#000000" },
      { name: "The Guardian", slug: "guardian", domain: "theguardian.com", category: "news", color: "#052962" },
      { name: "The Athletic", slug: "athletic", domain: "theathletic.com", category: "news", color: "#000000" },
      { name: "Medium", slug: "medium", domain: "medium.com", category: "news", color: "#000000" },
      { name: "Pocket", slug: "pocket", domain: "getpocket.com", category: "news", color: "#EF4056" },
      { name: "Instapaper", slug: "instapaper", domain: "instapaper.com", category: "news", color: "#000000" },
      { name: "Feedly", slug: "feedly", domain: "feedly.com", category: "news", color: "#2BB24C" },
      { name: "Inoreader", slug: "inoreader", domain: "inoreader.com", category: "news", color: "#007AFF" },
      { name: "The Information", slug: "information", domain: "theinformation.com", category: "news", color: "#000000" },
      { name: "Stratechery", slug: "stratechery", domain: "stratechery.com", category: "news", color: "#3D8BFF" },
      { name: "The Verge", slug: "verge", domain: "theverge.com", category: "news", color: "#000000" },
      { name: "Ars Technica", slug: "ars-technica", domain: "arstechnica.com", category: "news", color: "#FF4400" },
      { name: "TechCrunch", slug: "techcrunch", domain: "techcrunch.com", category: "news", color: "#0A9E01" },
      { name: "Reuters", slug: "reuters", domain: "reuters.com", category: "news", color: "#FF8000" },
      { name: "Associated Press", slug: "associated-press", domain: "apnews.com", category: "news", color: "#EF3E42" },
      { name: "BBC", slug: "bbc", domain: "bbc.com", category: "news", color: "#000000" },
      { name: "CNN", slug: "cnn", domain: "cnn.com", category: "news", color: "#CC0000" },
      { name: "TIME", slug: "time", domain: "time.com", category: "news", color: "#E90606" },
      { name: "Newsweek", slug: "newsweek", domain: "newsweek.com", category: "news", color: "#C2002F" },
      { name: "Vox", slug: "vox", domain: "vox.com", category: "news", color: "#F8E71C" },
      { name: "Polygon", slug: "polygon", domain: "polygon.com", category: "news", color: "#FF0063" },
      { name: "Kotaku", slug: "kotaku", domain: "kotaku.com", category: "news", color: "#000000" },
      { name: "IGN", slug: "ign", domain: "ign.com", category: "news", color: "#BF1313" },
      { name: "PC Gamer", slug: "pc-gamer", domain: "pcgamer.com", category: "news", color: "#E60012" },
      { name: "GQ", slug: "gq", domain: "gq.com", category: "news", color: "#000000" },
      { name: "Vanity Fair", slug: "vanity-fair", domain: "vanityfair.com", category: "news", color: "#000000" },

      # ============ FITNESS & WELLNESS (20+) ============
      { name: "Peloton", slug: "peloton", domain: "onepeloton.com", category: "fitness", color: "#000000" },
      { name: "Strava", slug: "strava", domain: "strava.com", category: "fitness", color: "#FC4C02" },
      { name: "MyFitnessPal", slug: "myfitnesspal", domain: "myfitnesspal.com", category: "fitness", color: "#0069D1" },
      { name: "Fitbit Premium", slug: "fitbit-premium", domain: "fitbit.com", category: "fitness", color: "#00B0B9" },
      { name: "Apple Fitness+", slug: "apple-fitness-plus", domain: "apple.com", category: "fitness", color: "#FA2D48" },
      { name: "Nike Training Club", slug: "nike-training-club", domain: "nike.com", category: "fitness", color: "#000000" },
      { name: "WHOOP", slug: "whoop", domain: "whoop.com", category: "fitness", color: "#000000" },
      { name: "Oura", slug: "oura", domain: "ouraring.com", category: "fitness", color: "#000000" },
      { name: "Noom", slug: "noom", domain: "noom.com", category: "fitness", color: "#F9C300" },
      { name: "WW (Weight Watchers)", slug: "weight-watchers", domain: "weightwatchers.com", category: "fitness", color: "#00A3E0" },
      { name: "Beachbody", slug: "beachbody", domain: "beachbody.com", category: "fitness", color: "#F26522" },
      { name: "Daily Burn", slug: "daily-burn", domain: "dailyburn.com", category: "fitness", color: "#ED6C2B" },
      { name: "Les Mills+", slug: "les-mills-plus", domain: "lesmills.com", category: "fitness", color: "#000000" },
      { name: "ClassPass", slug: "classpass", domain: "classpass.com", category: "fitness", color: "#00D1CA" },
      { name: "Gympass", slug: "gympass", domain: "gympass.com", category: "fitness", color: "#FF5A5F" },
      { name: "Centr", slug: "centr", domain: "centr.com", category: "fitness", color: "#1A1A1A" },
      { name: "Obe Fitness", slug: "obe-fitness", domain: "obefitness.com", category: "fitness", color: "#000000" },
      { name: "Alo Moves", slug: "alo-moves", domain: "alomoves.com", category: "fitness", color: "#000000" },
      { name: "Glo", slug: "glo", domain: "glo.com", category: "fitness", color: "#6D28D9" },
      { name: "Down Dog", slug: "down-dog", domain: "downdogapp.com", category: "fitness", color: "#3B82F6" },
      { name: "Ladder", slug: "ladder", domain: "joinladder.com", category: "fitness", color: "#000000" },

      # ============ CLOUD STORAGE (15+) ============
      { name: "iCloud+", slug: "icloud-plus", domain: "icloud.com", category: "storage", color: "#3693F3" },
      { name: "Google One", slug: "google-one", domain: "one.google.com", category: "storage", color: "#4285F4" },
      { name: "Google Drive", slug: "google-drive", domain: "drive.google.com", category: "storage", color: "#4285F4" },
      { name: "OneDrive", slug: "onedrive", domain: "onedrive.live.com", category: "storage", color: "#0078D4" },
      { name: "Backblaze", slug: "backblaze", domain: "backblaze.com", category: "storage", color: "#E21E26" },
      { name: "Carbonite", slug: "carbonite", domain: "carbonite.com", category: "storage", color: "#27B24A" },
      { name: "IDrive", slug: "idrive", domain: "idrive.com", category: "storage", color: "#003399" },
      { name: "pCloud", slug: "pcloud", domain: "pcloud.com", category: "storage", color: "#19B4D0" },
      { name: "Sync.com", slug: "sync-com", domain: "sync.com", category: "storage", color: "#5B9BD5" },
      { name: "Tresorit", slug: "tresorit", domain: "tresorit.com", category: "storage", color: "#00B74F" },
      { name: "SpiderOak", slug: "spideroak", domain: "spideroak.com", category: "storage", color: "#000000" },
      { name: "Box", slug: "box", domain: "box.com", category: "storage", color: "#0061D5" },
      { name: "MEGA", slug: "mega", domain: "mega.io", category: "storage", color: "#D9272E" },
      { name: "Internxt", slug: "internxt", domain: "internxt.com", category: "storage", color: "#0A84FF" },
      { name: "Icedrive", slug: "icedrive", domain: "icedrive.net", category: "storage", color: "#1A73E8" },

      # ============ CLOUD & DEV TOOLS (30+) ============
      { name: "GitHub", slug: "github", domain: "github.com", category: "cloud", color: "#181717" },
      { name: "GitLab", slug: "gitlab", domain: "gitlab.com", category: "cloud", color: "#FC6D26" },
      { name: "Bitbucket", slug: "bitbucket", domain: "bitbucket.org", category: "cloud", color: "#0052CC" },
      { name: "Vercel", slug: "vercel", domain: "vercel.com", category: "cloud", color: "#000000" },
      { name: "Netlify", slug: "netlify", domain: "netlify.com", category: "cloud", color: "#00C7B7" },
      { name: "Railway", slug: "railway", domain: "railway.app", category: "cloud", color: "#0B0D0E" },
      { name: "Render", slug: "render", domain: "render.com", category: "cloud", color: "#46E3B7" },
      { name: "Heroku", slug: "heroku", domain: "heroku.com", category: "cloud", color: "#430098" },
      { name: "DigitalOcean", slug: "digitalocean", domain: "digitalocean.com", category: "cloud", color: "#0080FF" },
      { name: "Linode", slug: "linode", domain: "linode.com", category: "cloud", color: "#00A95C" },
      { name: "Vultr", slug: "vultr", domain: "vultr.com", category: "cloud", color: "#007BFC" },
      { name: "AWS", slug: "aws", domain: "aws.amazon.com", category: "cloud", color: "#FF9900" },
      { name: "Google Cloud", slug: "google-cloud", domain: "cloud.google.com", category: "cloud", color: "#4285F4" },
      { name: "Microsoft Azure", slug: "microsoft-azure", domain: "azure.microsoft.com", category: "cloud", color: "#0078D4" },
      { name: "Cloudflare", slug: "cloudflare", domain: "cloudflare.com", category: "cloud", color: "#F38020" },
      { name: "Fastly", slug: "fastly", domain: "fastly.com", category: "cloud", color: "#FF282D" },
      { name: "Fly.io", slug: "fly-io", domain: "fly.io", category: "cloud", color: "#7B3FE4" },
      { name: "Supabase", slug: "supabase", domain: "supabase.com", category: "cloud", color: "#3ECF8E" },
      { name: "PlanetScale", slug: "planetscale", domain: "planetscale.com", category: "cloud", color: "#000000" },
      { name: "Neon", slug: "neon", domain: "neon.tech", category: "cloud", color: "#00E599" },
      { name: "MongoDB Atlas", slug: "mongodb-atlas", domain: "mongodb.com", category: "cloud", color: "#47A248" },
      { name: "Redis Cloud", slug: "redis-cloud", domain: "redis.com", category: "cloud", color: "#DC382D" },
      { name: "Algolia", slug: "algolia", domain: "algolia.com", category: "cloud", color: "#5468FF" },
      { name: "Elastic Cloud", slug: "elastic-cloud", domain: "elastic.co", category: "cloud", color: "#FEC514" },
      { name: "Sentry", slug: "sentry", domain: "sentry.io", category: "cloud", color: "#362D59" },
      { name: "Datadog", slug: "datadog", domain: "datadoghq.com", category: "cloud", color: "#632CA6" },
      { name: "New Relic", slug: "new-relic", domain: "newrelic.com", category: "cloud", color: "#008C99" },
      { name: "LaunchDarkly", slug: "launchdarkly", domain: "launchdarkly.com", category: "cloud", color: "#3DD6F5" },
      { name: "CircleCI", slug: "circleci", domain: "circleci.com", category: "cloud", color: "#343434" },
      { name: "Travis CI", slug: "travis-ci", domain: "travis-ci.com", category: "cloud", color: "#3EAAAF" },
      { name: "JetBrains", slug: "jetbrains", domain: "jetbrains.com", category: "cloud", color: "#000000" },
      { name: "Replit", slug: "replit", domain: "replit.com", category: "cloud", color: "#F26207" },
      { name: "CodeSandbox", slug: "codesandbox", domain: "codesandbox.io", category: "cloud", color: "#151515" },
      { name: "StackBlitz", slug: "stackblitz", domain: "stackblitz.com", category: "cloud", color: "#1389FD" },

      # ============ AI & LLM TOOLS (20+) ============
      { name: "Claude", slug: "claude", domain: "anthropic.com", category: "utilities", color: "#D97706" },
      { name: "ChatGPT Plus", slug: "chatgpt-plus", domain: "openai.com", category: "utilities", color: "#10A37F" },
      { name: "GitHub Copilot", slug: "github-copilot", domain: "github.com", category: "utilities", color: "#000000" },
      { name: "Cursor", slug: "cursor", domain: "cursor.com", category: "utilities", color: "#000000" },
      { name: "Midjourney", slug: "midjourney", domain: "midjourney.com", category: "utilities", color: "#000000" },
      { name: "DALL-E", slug: "dall-e", domain: "openai.com", category: "utilities", color: "#10A37F" },
      { name: "Stable Diffusion", slug: "stable-diffusion", domain: "stability.ai", category: "utilities", color: "#7C3AED" },
      { name: "Jasper", slug: "jasper", domain: "jasper.ai", category: "utilities", color: "#000000" },
      { name: "Copy.ai", slug: "copy-ai", domain: "copy.ai", category: "utilities", color: "#7C3AED" },
      { name: "Writesonic", slug: "writesonic", domain: "writesonic.com", category: "utilities", color: "#5B4FD9" },
      { name: "Notion AI", slug: "notion-ai", domain: "notion.so", category: "utilities", color: "#000000" },
      { name: "Perplexity", slug: "perplexity", domain: "perplexity.ai", category: "utilities", color: "#20808D" },
      { name: "Poe", slug: "poe", domain: "poe.com", category: "utilities", color: "#7B4F9D" },
      { name: "Character.AI", slug: "character-ai", domain: "character.ai", category: "utilities", color: "#5B4DC9" },
      { name: "Replicate", slug: "replicate", domain: "replicate.com", category: "utilities", color: "#000000" },
      { name: "Hugging Face", slug: "hugging-face", domain: "huggingface.co", category: "utilities", color: "#FFD21E" },
      { name: "Cohere", slug: "cohere", domain: "cohere.com", category: "utilities", color: "#39594D" },
      { name: "RunwayML", slug: "runwayml", domain: "runwayml.com", category: "utilities", color: "#000000" },
      { name: "ElevenLabs", slug: "elevenlabs", domain: "elevenlabs.io", category: "utilities", color: "#000000" },
      { name: "Descript", slug: "descript", domain: "descript.com", category: "utilities", color: "#00D179" },

      # ============ SECURITY & VPN (15+) ============
      { name: "NordVPN", slug: "nordvpn", domain: "nordvpn.com", category: "utilities", color: "#4687FF" },
      { name: "ExpressVPN", slug: "expressvpn", domain: "expressvpn.com", category: "utilities", color: "#DA3940" },
      { name: "Surfshark", slug: "surfshark", domain: "surfshark.com", category: "utilities", color: "#178DEA" },
      { name: "ProtonVPN", slug: "protonvpn", domain: "protonvpn.com", category: "utilities", color: "#6D4AFF" },
      { name: "Private Internet Access", slug: "private-internet-access", domain: "privateinternetaccess.com", category: "utilities", color: "#4BB543" },
      { name: "CyberGhost", slug: "cyberghost", domain: "cyberghostvpn.com", category: "utilities", color: "#FDCB58" },
      { name: "Mullvad", slug: "mullvad", domain: "mullvad.net", category: "utilities", color: "#294D73" },
      { name: "IVPN", slug: "ivpn", domain: "ivpn.net", category: "utilities", color: "#5B8FDB" },
      { name: "Proton Mail", slug: "proton-mail", domain: "proton.me", category: "utilities", color: "#6D4AFF" },
      { name: "Tutanota", slug: "tutanota", domain: "tutanota.com", category: "utilities", color: "#840010" },
      { name: "Fastmail", slug: "fastmail", domain: "fastmail.com", category: "utilities", color: "#69A3CE" },
      { name: "Hey", slug: "hey", domain: "hey.com", category: "utilities", color: "#5522FA" },
      { name: "Norton", slug: "norton", domain: "norton.com", category: "utilities", color: "#FFC800" },
      { name: "McAfee", slug: "mcafee", domain: "mcafee.com", category: "utilities", color: "#C01818" },
      { name: "Malwarebytes", slug: "malwarebytes", domain: "malwarebytes.com", category: "utilities", color: "#0A71C7" },

      # ============ FINANCE & BUDGETING (15+) ============
      { name: "YNAB", slug: "ynab", domain: "ynab.com", category: "utilities", color: "#85C3E9" },
      { name: "Mint", slug: "mint", domain: "mint.intuit.com", category: "utilities", color: "#00A86B" },
      { name: "Copilot Money", slug: "copilot-money", domain: "copilot.money", category: "utilities", color: "#000000" },
      { name: "Monarch Money", slug: "monarch-money", domain: "monarchmoney.com", category: "utilities", color: "#6D28D9" },
      { name: "Tiller Money", slug: "tiller-money", domain: "tillerhq.com", category: "utilities", color: "#2D72D2" },
      { name: "Personal Capital", slug: "personal-capital", domain: "personalcapital.com", category: "utilities", color: "#003D4C" },
      { name: "Quicken", slug: "quicken", domain: "quicken.com", category: "utilities", color: "#E01E3B" },
      { name: "QuickBooks", slug: "quickbooks", domain: "quickbooks.intuit.com", category: "utilities", color: "#2CA01C" },
      { name: "FreshBooks", slug: "freshbooks", domain: "freshbooks.com", category: "utilities", color: "#0075DD" },
      { name: "Wave", slug: "wave", domain: "waveapps.com", category: "utilities", color: "#1C3B57" },
      { name: "Xero", slug: "xero", domain: "xero.com", category: "utilities", color: "#13B5EA" },
      { name: "Bench", slug: "bench", domain: "bench.co", category: "utilities", color: "#FF6B35" },
      { name: "Pilot", slug: "pilot", domain: "pilot.com", category: "utilities", color: "#6B4EFF" },
      { name: "Gusto", slug: "gusto", domain: "gusto.com", category: "utilities", color: "#F45D48" },
      { name: "Deel", slug: "deel", domain: "deel.com", category: "utilities", color: "#15357A" },

      # ============ EDUCATION (15+) ============
      { name: "Coursera", slug: "coursera", domain: "coursera.org", category: "education", color: "#0056D2" },
      { name: "Udemy", slug: "udemy", domain: "udemy.com", category: "education", color: "#A435F0" },
      { name: "LinkedIn Learning", slug: "linkedin-learning", domain: "linkedin.com", category: "education", color: "#0A66C2" },
      { name: "Skillshare", slug: "skillshare", domain: "skillshare.com", category: "education", color: "#00FF84" },
      { name: "MasterClass", slug: "masterclass", domain: "masterclass.com", category: "education", color: "#000000" },
      { name: "Brilliant", slug: "brilliant", domain: "brilliant.org", category: "education", color: "#000000" },
      { name: "Duolingo", slug: "duolingo", domain: "duolingo.com", category: "education", color: "#58CC02" },
      { name: "Babbel", slug: "babbel", domain: "babbel.com", category: "education", color: "#F27405" },
      { name: "Rosetta Stone", slug: "rosetta-stone", domain: "rosettastone.com", category: "education", color: "#2E5893" },
      { name: "Codecademy", slug: "codecademy", domain: "codecademy.com", category: "education", color: "#1F4056" },
      { name: "DataCamp", slug: "datacamp", domain: "datacamp.com", category: "education", color: "#05192D" },
      { name: "Pluralsight", slug: "pluralsight", domain: "pluralsight.com", category: "education", color: "#F15B2A" },
      { name: "Frontend Masters", slug: "frontend-masters", domain: "frontendmasters.com", category: "education", color: "#C02D28" },
      { name: "Egghead.io", slug: "egghead-io", domain: "egghead.io", category: "education", color: "#252526" },
      { name: "Treehouse", slug: "treehouse", domain: "teamtreehouse.com", category: "education", color: "#5FCF80" },
      { name: "Khan Academy", slug: "khan-academy", domain: "khanacademy.org", category: "education", color: "#14BF96" },
      { name: "edX", slug: "edx", domain: "edx.org", category: "education", color: "#02262B" },
      { name: "Blinkist", slug: "blinkist", domain: "blinkist.com", category: "education", color: "#01B375" },
      { name: "Wondrium", slug: "wondrium", domain: "wondrium.com", category: "education", color: "#1A1A1A" }
    ]

    created_count = 0
    updated_count = 0
    skipped_count = 0

    services.each do |service_data|
      service = SubscriptionService.find_by(slug: service_data[:slug])

      if service
        if service.update(service_data.except(:slug))
          updated_count += 1
        else
          skipped_count += 1
          puts "  Skipped #{service_data[:name]}: #{service.errors.full_messages.join(', ')}"
        end
      else
        service = SubscriptionService.new(service_data)
        if service.save
          created_count += 1
        else
          skipped_count += 1
          puts "  Failed to create #{service_data[:name]}: #{service.errors.full_messages.join(', ')}"
        end
      end
    end

    puts "Done! Created: #{created_count}, Updated: #{updated_count}, Skipped: #{skipped_count}"
    puts "Total subscription services: #{SubscriptionService.count}"
  end

  desc "List all subscription services by category"
  task list: :environment do
    SubscriptionService::CATEGORIES.each do |category|
      services = SubscriptionService.where(category: category).order(:name)
      puts "\n#{category.upcase} (#{services.count}):"
      services.each do |s|
        puts "  - #{s.name} (#{s.domain})"
      end
    end
    puts "\nTotal: #{SubscriptionService.count} services"
  end

  desc "Auto-match existing subscriptions to services by name"
  task match_existing: :environment do
    puts "Matching existing subscriptions to services..."
    matched = 0
    unmatched = []

    Family.find_each do |family|
      family.recurring_transactions.subscriptions.where(subscription_service_id: nil).find_each do |sub|
        display_name = sub.display_name.downcase.strip

        # 1. Exact match
        service = SubscriptionService.where("LOWER(name) = ?", display_name).first

        # 2. Service name contains subscription name
        service ||= SubscriptionService.where("LOWER(name) LIKE ?", "%#{display_name}%").first

        # 3. Subscription name contains service name
        service ||= SubscriptionService.where("? LIKE '%' || LOWER(name) || '%'", display_name).first

        # 4. Word-based matching
        unless service
          words = display_name.split(/\s+/).reject { |w| w.length < 3 || %w[the a an].include?(w) }
          words.each do |word|
            service = SubscriptionService.where("LOWER(name) LIKE ?", "#{word}%").first
            break if service
          end
        end

        if service
          sub.update!(subscription_service_id: service.id)
          puts "  ✓ #{sub.display_name} → #{service.name}"
          matched += 1
        else
          unmatched << sub.display_name
        end
      end
    end

    puts "\nMatched: #{matched} subscriptions"
    if unmatched.any?
      puts "Unmatched (#{unmatched.size}):"
      unmatched.each { |name| puts "  ✗ #{name}" }
    end
  end
end
