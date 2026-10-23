#if DEBUG
import Foundation
import TriCrypto

/// Debug-only: a full, lived-in demo vault (200+ items in folders) for screenshots — `Triwarden --demo-full`.
/// Same every run (a fixed seed), and only made-up people: Alex Chen and the Northwind company.
@MainActor
enum DemoVault {
    static let folders: [Grouping] = [
        Grouping(id: "f-personal", name: "Personal"), Grouping(id: "f-work", name: "Work"),
        Grouping(id: "f-dev", name: "Developer"), Grouping(id: "f-finance", name: "Finance"),
        Grouping(id: "f-shopping", name: "Shopping"), Grouping(id: "f-social", name: "Social"),
        Grouping(id: "f-media", name: "Entertainment"), Grouping(id: "f-travel", name: "Travel"),
        Grouping(id: "f-home", name: "Home Lab"),
    ]

    /// Northwind, the shared vault at work, with shared folders that nest (Engineering › Backend).
    static let organizations: [Grouping] = [
        Grouping(id: "org-northwind", name: "Northwind", children: [
            Grouping(id: "col-eng", name: "Engineering", canWrite: true),
            Grouping(id: "col-eng-backend", name: "Engineering/Backend", canWrite: true),
            Grouping(id: "col-eng-frontend", name: "Engineering/Frontend", canWrite: true),
            Grouping(id: "col-ops", name: "Operations", canWrite: true),
            Grouping(id: "col-people", name: "People & Finance", canWrite: true),
        ]),
    ]

    /// Work logins that live in Northwind's vault rather than Alex's own, and the shared folder each is in.
    private static let shared: [String: String] = [
        "Datadog": "col-eng-backend", "PagerDuty": "col-eng-backend", "Grafana": "col-eng-backend",
        "northwind-deploy": "col-eng-backend",
        "Figma": "col-eng-frontend", "Linear": "col-eng-frontend", "Lucidchart": "col-eng-frontend",
        "Jira": "col-eng", "Confluence": "col-eng",
        "Northwind Google Workspace": "col-ops", "Slack — Northwind": "col-ops", "Okta": "col-ops",
        "VPN — Northwind": "col-ops", "Intranet": "col-ops", "Zoom": "col-ops",
        "Workday": "col-people", "BambooHR": "col-people", "Expensify": "col-people", "DocuSign": "col-people",
        "Northwind Corporate": "col-people",
    ]

    /// The curated demo items, then the generated rest; Northwind's out of Alex's folders and into its shared folders.
    static var items: [VaultItem] {
        (Snapshot.demoItems + generated).map { item in
            guard let collection = shared[item.name] else { return item }
            var item = item
            item.organizationId = "org-northwind"
            item.collectionIds = [collection]
            item.folderId = nil
            item.folderName = nil
            return item
        }
    }

    private static let work = "alex.chen@northwind.example"
    private static let mail = "alex.chen@gmail.com"

    // (name, host, folder, username) — the username nil means the usual personal email.
    private static let logins: [(String, String, String, String?)] = [
        // Developer
        ("GitLab", "gitlab.com", "f-dev", "alexchen"), ("Bitbucket", "bitbucket.org", "f-dev", nil),
        ("npm", "npmjs.com", "f-dev", "alexchen"), ("PyPI", "pypi.org", "f-dev", "alexchen"),
        ("Docker Hub", "hub.docker.com", "f-dev", "alexchen"), ("Vercel", "vercel.com", "f-dev", nil),
        ("Netlify", "app.netlify.com", "f-dev", nil), ("Fly.io", "fly.io", "f-dev", nil),
        ("DigitalOcean", "cloud.digitalocean.com", "f-dev", nil), ("Hetzner Cloud", "console.hetzner.cloud", "f-dev", nil),
        ("AWS Console", "console.aws.amazon.com", "f-dev", "alex-admin"), ("Google Cloud", "console.cloud.google.com", "f-dev", nil),
        ("Azure Portal", "portal.azure.com", "f-dev", nil), ("Supabase", "supabase.com", "f-dev", nil),
        ("Sentry", "sentry.io", "f-dev", nil), ("Postman", "postman.com", "f-dev", nil),
        ("Stack Overflow", "stackoverflow.com", "f-dev", nil), ("JetBrains Account", "account.jetbrains.com", "f-dev", nil),
        ("Apple Developer", "developer.apple.com", "f-dev", nil), ("App Store Connect", "appstoreconnect.apple.com", "f-dev", nil),
        ("Google Play Console", "play.google.com", "f-dev", nil), ("Codeberg", "codeberg.org", "f-dev", "alexchen"),
        ("Hugging Face", "huggingface.co", "f-dev", "alexchen"), ("Linode", "cloud.linode.com", "f-dev", nil),
        ("Render", "dashboard.render.com", "f-dev", nil), ("Railway", "railway.app", "f-dev", nil),
        ("Heroku", "id.heroku.com", "f-dev", nil), ("CircleCI", "app.circleci.com", "f-dev", nil),
        ("Codecov", "app.codecov.io", "f-dev", nil), ("Namecheap", "namecheap.com", "f-dev", "alexchen"),
        ("Porkbun", "porkbun.com", "f-dev", nil), ("Backblaze B2", "secure.backblaze.com", "f-dev", nil),
        // Work
        ("Northwind Google Workspace", "accounts.google.com", "f-work", work), ("Slack — Northwind", "northwind.slack.com", "f-work", work),
        ("Jira", "northwind.atlassian.net", "f-work", work), ("Confluence", "northwind.atlassian.net", "f-work", work),
        ("Linear", "linear.app", "f-work", work), ("Notion", "notion.so", "f-work", work),
        ("Figma", "figma.com", "f-work", work), ("Zoom", "zoom.us", "f-work", work),
        ("Microsoft 365", "login.microsoftonline.com", "f-work", work), ("Okta", "northwind.okta.com", "f-work", work),
        ("1:1 Notes — Miro", "miro.com", "f-work", work), ("Loom", "loom.com", "f-work", work),
        ("Asana", "app.asana.com", "f-work", work), ("Workday", "northwind.workday.com", "f-work", work),
        ("BambooHR", "northwind.bamboohr.com", "f-work", work), ("Expensify", "expensify.com", "f-work", work),
        ("DocuSign", "account.docusign.com", "f-work", work), ("Calendly", "calendly.com", "f-work", work),
        ("Datadog", "app.datadoghq.com", "f-work", work), ("PagerDuty", "northwind.pagerduty.com", "f-work", work),
        ("Grafana", "grafana.northwind.example", "f-work", "alex"), ("VPN — Northwind", "vpn.northwind.example", "f-work", "achen"),
        ("Intranet", "intranet.northwind.example", "f-work", "achen"), ("HubSpot", "app.hubspot.com", "f-work", work),
        ("Salesforce", "login.salesforce.com", "f-work", work), ("Zendesk", "northwind.zendesk.com", "f-work", work),
        ("Dropbox — Work", "dropbox.com", "f-work", work), ("Box", "account.box.com", "f-work", work),
        ("Webex", "webex.com", "f-work", work), ("Lucidchart", "lucid.app", "f-work", work),
        // Finance
        ("Chase", "chase.com", "f-finance", "alexchen88"), ("American Express", "americanexpress.com", "f-finance", "alexchen88"),
        ("PayPal", "paypal.com", "f-finance", nil), ("Wise", "wise.com", "f-finance", nil),
        ("Revolut", "revolut.com", "f-finance", nil), ("Fidelity", "fidelity.com", "f-finance", "achen-invest"),
        ("Vanguard", "investor.vanguard.com", "f-finance", "achen-invest"), ("Charles Schwab", "schwab.com", "f-finance", "achen-invest"),
        ("Interactive Brokers", "interactivebrokers.com", "f-finance", "achen88"), ("Coinbase", "coinbase.com", "f-finance", nil),
        ("Kraken", "kraken.com", "f-finance", nil), ("Venmo", "venmo.com", "f-finance", nil),
        ("Mint Mobile", "mintmobile.com", "f-finance", nil), ("TurboTax", "turbotax.intuit.com", "f-finance", nil),
        ("YNAB", "app.ynab.com", "f-finance", nil), ("Stripe", "dashboard.stripe.com", "f-finance", nil),
        ("Capital One", "capitalone.com", "f-finance", "alexchen88"), ("Discover", "discover.com", "f-finance", "alexchen88"),
        ("Credit Karma", "creditkarma.com", "f-finance", nil), ("Experian", "experian.com", "f-finance", nil),
        // Shopping
        ("Amazon", "amazon.com", "f-shopping", nil), ("eBay", "ebay.com", "f-shopping", "alexchen_88"),
        ("Etsy", "etsy.com", "f-shopping", nil), ("Best Buy", "bestbuy.com", "f-shopping", nil),
        ("Target", "target.com", "f-shopping", nil), ("Costco", "costco.com", "f-shopping", nil),
        ("IKEA", "ikea.com", "f-shopping", nil), ("Uniqlo", "uniqlo.com", "f-shopping", nil),
        ("Apple Store", "apple.com", "f-shopping", nil), ("B&H Photo", "bhphotovideo.com", "f-shopping", nil),
        ("Newegg", "newegg.com", "f-shopping", nil), ("Muji", "muji.us", "f-shopping", nil),
        ("REI", "rei.com", "f-shopping", nil), ("Instacart", "instacart.com", "f-shopping", nil),
        ("DoorDash", "doordash.com", "f-shopping", nil), ("Uber Eats", "ubereats.com", "f-shopping", nil),
        ("AliExpress", "aliexpress.com", "f-shopping", nil), ("Shopify", "accounts.shopify.com", "f-shopping", nil),
        ("Patagonia", "patagonia.com", "f-shopping", nil), ("Nike", "nike.com", "f-shopping", nil),
        // Social
        ("Mastodon", "mastodon.social", "f-social", "@alexchen"), ("Bluesky", "bsky.app", "f-social", "alexchen.bsky.social"),
        ("Reddit", "reddit.com", "f-social", "quiet_alex"), ("LinkedIn", "linkedin.com", "f-social", nil),
        ("Instagram", "instagram.com", "f-social", "alex.takes.photos"), ("Threads", "threads.net", "f-social", "alex.takes.photos"),
        ("Facebook", "facebook.com", "f-social", nil), ("X", "x.com", "f-social", "alexchen_dev"),
        ("Discord", "discord.com", "f-social", "alexc"), ("Telegram", "web.telegram.org", "f-social", "+1 415 555 0142"),
        ("Signal", "signal.org", "f-social", "+1 415 555 0142"), ("WhatsApp Web", "web.whatsapp.com", "f-social", "+1 415 555 0142"),
        ("Pinterest", "pinterest.com", "f-social", nil), ("Strava", "strava.com", "f-social", nil),
        ("Goodreads", "goodreads.com", "f-social", nil), ("Meetup", "meetup.com", "f-social", nil),
        ("Hacker News", "news.ycombinator.com", "f-social", "alexc"), ("Lobsters", "lobste.rs", "f-social", "alexc"),
        // Entertainment
        ("Netflix", "netflix.com", "f-media", nil), ("Spotify", "spotify.com", "f-media", nil),
        ("YouTube Premium", "youtube.com", "f-media", nil), ("Disney+", "disneyplus.com", "f-media", nil),
        ("Max", "max.com", "f-media", nil), ("Apple TV+", "tv.apple.com", "f-media", nil),
        ("Steam", "store.steampowered.com", "f-media", "alexc_plays"), ("Epic Games", "epicgames.com", "f-media", nil),
        ("Nintendo Account", "accounts.nintendo.com", "f-media", nil), ("PlayStation Network", "playstation.com", "f-media", nil),
        ("Xbox", "xbox.com", "f-media", nil), ("Twitch", "twitch.tv", "f-media", "alexc_plays"),
        ("Audible", "audible.com", "f-media", nil), ("Kindle", "read.amazon.com", "f-media", nil),
        ("Plex", "app.plex.tv", "f-media", nil), ("Letterboxd", "letterboxd.com", "f-media", "alexc"),
        ("Crunchyroll", "crunchyroll.com", "f-media", nil), ("Tidal", "tidal.com", "f-media", nil),
        ("Patreon", "patreon.com", "f-media", nil), ("Substack", "substack.com", "f-media", nil),
        // Travel
        ("Airbnb", "airbnb.com", "f-travel", nil), ("Booking.com", "booking.com", "f-travel", nil),
        ("United MileagePlus", "united.com", "f-travel", "MP 4821 0093"), ("Delta SkyMiles", "delta.com", "f-travel", "9104 2276 18"),
        ("Cathay Pacific", "cathaypacific.com", "f-travel", "1840 2291 77"), ("Japan Airlines", "jal.co.jp", "f-travel", "JMB 402 118 330"),
        ("Marriott Bonvoy", "marriott.com", "f-travel", nil), ("Hilton Honors", "hilton.com", "f-travel", nil),
        ("Expedia", "expedia.com", "f-travel", nil), ("Uber", "uber.com", "f-travel", nil),
        ("Lyft", "lyft.com", "f-travel", nil), ("Google Flights", "flights.google.com", "f-travel", nil),
        ("TSA PreCheck", "tsa.gov", "f-travel", nil), ("Global Entry", "ttp.cbp.dhs.gov", "f-travel", nil),
        ("Hertz", "hertz.com", "f-travel", nil), ("Klook", "klook.com", "f-travel", nil),
        // Home lab
        ("Proxmox", "pve.home.arpa", "f-home", "root@pam"), ("Home Assistant", "ha.home.arpa", "f-home", "alex"),
        ("Pi-hole", "pihole.home.arpa", "f-home", "admin"), ("UniFi Controller", "unifi.home.arpa", "f-home", "alex"),
        ("TrueNAS", "truenas.home.arpa", "f-home", "admin"), ("Jellyfin", "media.home.arpa", "f-home", "alex"),
        ("Nextcloud", "cloud.home.arpa", "f-home", "alex"), ("Gitea", "git.home.arpa", "f-home", "alex"),
        ("Grafana — Home", "grafana.home.arpa", "f-home", "admin"), ("Portainer", "portainer.home.arpa", "f-home", "admin"),
        ("Vaultwarden Admin", "vault.home.arpa", "f-home", "admin"), ("Router", "192.168.1.1", "f-home", "admin"),
        ("Immich", "photos.home.arpa", "f-home", "alex"), ("Paperless-ngx", "docs.home.arpa", "f-home", "alex"),
        ("Uptime Kuma", "status.home.arpa", "f-home", "admin"), ("Frigate", "nvr.home.arpa", "f-home", "admin"),
        ("Wi-Fi Printer", "printer.home.arpa", "f-home", "admin"), ("Mosquitto", "mqtt.home.arpa", "f-home", "ha"),
        // Personal
        ("Google", "accounts.google.com", "f-personal", nil), ("iCloud", "icloud.com", "f-personal", "alex.chen@icloud.com"),
        ("Microsoft Account", "account.microsoft.com", "f-personal", nil), ("Fastmail", "fastmail.com", "f-personal", "alex@chen.fastmail.com"),
        ("Dropbox", "dropbox.com", "f-personal", nil), ("Duolingo", "duolingo.com", "f-personal", nil),
        ("Kaiser Permanente", "kp.org", "f-personal", "achen1988"), ("Comcast Xfinity", "xfinity.com", "f-personal", nil),
        ("PG&E", "pge.com", "f-personal", nil), ("USPS Informed Delivery", "usps.com", "f-personal", nil),
        ("DMV", "dmv.ca.gov", "f-personal", nil), ("IRS", "irs.gov", "f-personal", nil),
        ("Coursera", "coursera.org", "f-personal", nil), ("Khan Academy", "khanacademy.org", "f-personal", nil),
        ("MyFitnessPal", "myfitnesspal.com", "f-personal", nil), ("Peloton", "onepeloton.com", "f-personal", nil),
        ("Headspace", "headspace.com", "f-personal", nil), ("Evernote", "evernote.com", "f-personal", nil),
        ("Todoist", "todoist.com", "f-personal", nil), ("Obsidian Sync", "obsidian.md", "f-personal", nil),
    ]

    private static let notes: [(String, String, String)] = [
        ("Wi-Fi — Home", "f-home", "Network: maple-house\nPassword: rain-cedar-lantern-42"),
        ("Wi-Fi — Guest", "f-home", "Network: maple-guest\nPassword: sunny-4821"),
        ("Router recovery", "f-home", "Admin PIN 7781. Factory reset: hold 10 s."),
        ("Alarm system code", "f-home", "Arm 2468 · Duress 2469"),
        ("Garage door", "f-home", "Keypad 9034"),
        ("Passport details", "f-personal", "Number in the identity item. Renew before 2031."),
        ("Health insurance", "f-personal", "Member ID KP-0042-88143 · Group 7710"),
        ("Car — Model 3", "f-personal", "VIN 5YJ3E1EA7PF000000\nInsurance policy GE-4410-2290"),
        ("Recovery kit — Google", "f-personal", "Backup codes: 4821 0093 · 7716 2201 · 9902 4417 · 3108 5562"),
        ("Recovery kit — Apple ID", "f-personal", "Recovery key: LQ7M-2F8X-K9PR-4WTC-H3NB-6YDE-8VJA"),
        ("Server notes", "f-dev", "Prod DB is read-only from the bastion; deploys go through CI."),
        ("Release signing", "f-dev", "Developer ID cert expires 2030-03. Notary profile: northwind-notary."),
        ("On-call runbook", "f-work", "Escalation: PagerDuty → #incidents → VP Eng after 30 min."),
        ("Office door", "f-work", "Badge PIN 5521"),
        ("Gift ideas", "f-personal", "Mum: ceramics class · Sam: new climbing shoes"),
        ("Locker combo", "f-personal", "24 · 08 · 16"),
    ]

    /// A few of the usual sins, so Watchtower has something to show.
    private static let weakPasswords: [String: String] = [
        "Router": "admin123", "Pi-hole": "admin123", "Wi-Fi Printer": "password1",
        "Meetup": "Summer2019!", "Goodreads": "Summer2019!", "Pinterest": "Summer2019!", "Hertz": "qwerty12",
    ]
    private static let stale: Set<String> = ["Comcast Xfinity", "PG&E", "Experian", "Lyft", "Evernote", "Kindle"]
    /// Seen in breaches (for the demo's Watchtower).
    static let breached: [String: Int] = ["Pinterest": 3_412, "Evernote": 58, "Goodreads": 211]

    private static var generated: [VaultItem] {
        var rng = SeededRandom(seed: 0x7472_6977)
        var items: [VaultItem] = []
        let folderName = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0.name) })
        let base = Date(timeIntervalSince1970: 1_560_000_000) // mid-2019
        func date(_ rng: inout SeededRandom) -> Date { base.addingTimeInterval(Double(rng.next(upTo: 230_000_000))) }

        for (index, entry) in logins.enumerated() {
            let (name, host, folder, user) = entry
            var item = VaultItem(id: "g\(index)", name: name, username: user ?? (folder == "f-work" ? work : mail), host: host,
                                 password: rng.password(), totp: rng.next(upTo: 100) < 30 ? TOTP(rng.base32(32)) : nil,
                                 notes: nil, favorite: rng.next(upTo: 100) < 7,
                                 hasPasskey: rng.next(upTo: 100) < 12)
            item.folderId = folder
            item.folderName = folderName[folder]
            item.created = date(&rng)
            item.revised = item.created.map { max($0, date(&rng)) }
            if let weak = weakPasswords[name] {
                item = VaultItem(id: item.id, name: name, username: item.username, host: host, password: weak, totp: item.totp,
                                 notes: nil, favorite: false, folderId: folder, folderName: folderName[folder],
                                 created: item.created)
                item.reuseCount = weakPasswords.values.filter { $0 == weak }.count - 1
            }
            if stale.contains(name) { item.passwordRevised = Date(timeIntervalSince1970: 1_561_000_000) }
            items.append(item)
        }
        for (index, entry) in notes.enumerated() {
            var item = VaultItem(id: "n\(index)", kind: .note, name: entry.0, username: nil, host: nil, password: nil,
                                 totp: nil, notes: entry.2, favorite: index == 0)
            item.folderId = entry.1
            item.folderName = folderName[entry.1]
            item.created = date(&rng)
            items.append(item)
        }
        let cards: [(String, String, String, String)] = [
            ("Chase Sapphire", "Visa", "4111111111111111", "f-finance"), ("Amex Gold", "Amex", "378282246310005", "f-finance"),
            ("Northwind Corporate", "Mastercard", "5555555555554444", "f-work"), ("Debit — Schwab", "Visa", "4012888888881881", "f-finance"),
        ]
        for (index, card) in cards.enumerated() {
            var item = VaultItem(id: "c\(index)", kind: .card, name: card.0, username: "•••• " + card.2.suffix(4), host: nil,
                                 password: nil, totp: nil, notes: nil, favorite: false,
                                 fields: [ItemField(label: "Card number", value: card.2, secret: true, monospaced: true),
                                          ItemField(label: "Cardholder", value: "Alex Chen"),
                                          ItemField(label: "Expires", value: "0\(index + 3)/20\(28 + index)"),
                                          ItemField(label: "Security code", value: "\(400 + index * 37)", secret: true, monospaced: true)])
            item.properties = ["brand": card.1, "number": card.2, "cardholderName": "Alex Chen"]
            item.folderId = card.3
            item.folderName = folderName[card.3]
            items.append(item)
        }
        let identities: [(String, [ItemField])] = [
            ("Alex Chen", [ItemField(label: "Name", value: "Alex Chen"), ItemField(label: "Email", value: mail),
                           ItemField(label: "Phone", value: "+1 415 555 0142"),
                           ItemField(label: "Address", value: "1200 Maple Street\nSan Francisco, CA 94110")]),
            ("Passport", [ItemField(label: "Name", value: "Alex Chen"), ItemField(label: "Passport number", value: "X48210093", secret: true)]),
            ("Driver's licence", [ItemField(label: "Name", value: "Alex Chen"), ItemField(label: "Licence number", value: "D4410228", secret: true)]),
        ]
        for (index, identity) in identities.enumerated() {
            var item = VaultItem(id: "i\(index)", kind: .identity, name: identity.0, username: "Alex Chen", host: nil,
                                 password: nil, totp: nil, notes: nil, favorite: false, fields: identity.1)
            item.folderId = "f-personal"
            item.folderName = "Personal"
            items.append(item)
        }
        for (index, key) in ["northwind-deploy", "github-signing", "proxmox-root", "raspberry-pi", "backup-offsite"].enumerated() {
            var item = VaultItem(id: "k\(index)", kind: .sshKey, name: key, username: nil, host: nil, password: nil,
                                 totp: nil, notes: nil, favorite: false,
                                 fields: [ItemField(label: "Fingerprint", value: "SHA256:\(rng.token(43))", monospaced: true)])
            item.folderId = index == 0 ? "f-work" : "f-dev"
            item.folderName = folderName[item.folderId!]
            items.append(item)
        }
        return items
    }
}

/// SplitMix64: a tiny deterministic generator, so the demo vault looks the same every run.
private struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(upTo bound: Int) -> Int { Int(next() % UInt64(bound)) }

    mutating func token(_ length: Int) -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789+/")
        return String((0..<length).map { _ in chars[next(upTo: chars.count)] })
    }

    mutating func base32(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        return String((0..<length).map { _ in chars[next(upTo: chars.count)] })
    }

    mutating func password() -> String {
        let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!#$%&*@^")
        return String((0..<(14 + next(upTo: 8))).map { _ in chars[next(upTo: chars.count)] })
    }
}
#endif

#if DEBUG
import AppKit
import SwiftUI
import VaultwardenAPI

/// Debug-only: `Triwarden --demo-full --shoot [-appearance dark]` steps through the screens worth showing, captures
/// its own windows (shadow included, as the window server draws them) into the app's temporary folder (it's
/// sandboxed), prints that folder and quits. An app may capture its own windows without the Screen Recording permission.
@MainActor
enum DemoShots {
    static func runIfRequested(_ model: AppModel) {
        let args = CommandLine.arguments
        guard args.contains("--shoot") else { return }
        let dir = FileManager.default.temporaryDirectory.appending(path: "demo-shots", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for old in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: old)
        }
        let scheme = UserDefaults.standard.string(forKey: Pref.appearance) == "dark" ? "dark" : "light"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { exit(1) }
            // Tall enough for the whole sidebar (Tools included), so it never scrolls under the traffic lights.
            window.setContentSize(NSSize(width: 1240, height: 930))
            window.center()
            // Front and key, so the traffic lights and selection show in colour.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)

            // The vault, an item with a one-time code and a passkey open.
            model.requestedSection = .section(.all)
            model.selectedID = "2"
            try? await Task.sleep(for: .seconds(2.5))
            await capture([window], dir.appending(path: "vault-\(scheme).png"))

            // Search across several vaults with filters on: My vault + Northwind, logins with a one-time code, the
            // shared folders open in the sidebar (My Folders folded, so Northwind is in view).
            let foldersOpen = UserDefaults.standard.object(forKey: "sidebarFoldersExpanded")
            UserDefaults.standard.set(false, forKey: "sidebarFoldersExpanded")
            model.vaultFilter = .several([AppModel.VaultFilter.personalKey, "org-northwind"])
            model.searchFilters = SearchFilters(type: .login)
            model.requestedFilter = "north" // one search over both: Alex's own work logins and Northwind's
            try? await Task.sleep(for: .seconds(0.5))
            model.selectedID = model.vaultItems.first { $0.organizationId != nil && $0.hasTOTP && $0.kind == .login }?.id
            try? await Task.sleep(for: .seconds(2))
            await capture([window], dir.appending(path: "search-\(scheme).png"))
            model.vaultFilter = .all
            model.searchFilters = SearchFilters()
            model.requestedFilter = ""
            UserDefaults.standard.set(foldersOpen, forKey: "sidebarFoldersExpanded")
            model.selectedID = "2"

            // As if opened over github.com in Safari (not whatever app is really in front).
            model.foreground = ForegroundContext(app: "Safari", bundleID: "com.apple.Safari", pid: 0, host: "github.com")
            model.foregroundPinned = true

            // The menu bar panel itself: a click on Triwarden's menu bar icon opens it, as a person would.
            if let button = NSApp.windows.lazy.compactMap({ $0.contentView.flatMap(Self.statusButton) }).first {
                let before = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
                button.performClick(nil)
                try? await Task.sleep(for: .seconds(2.5))
                if let panel = NSApp.windows.first(where: { $0.isVisible && !before.contains($0.windowNumber) }) {
                    await capture([panel], dir.appending(path: "menubar-\(scheme).png"), activate: false)
                    panel.orderOut(nil)
                }
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            let appearance = NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua)!
            let host = NSHostingView(rootView: MenuBarContent().environment(model).tint(.brand))
            host.appearance = appearance
            host.layoutSubtreeIfNeeded()
            host.frame.size = host.fittingSize
            // Opaque: captured on its own, a translucent material would have nothing behind it and turn grey.
            let glass = NSView(frame: NSRect(origin: .zero, size: host.frame.size))
            glass.appearance = appearance
            glass.wantsLayer = true
            appearance.performAsCurrentDrawingAppearance { glass.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
            glass.layer?.cornerRadius = 14
            glass.layer?.masksToBounds = true
            glass.addSubview(host)
            let panel = NSPanel(contentRect: glass.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .popUpMenu
            panel.contentView = glass
            panel.appearance = appearance
            if let screen = window.screen?.visibleFrame {
                panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - glass.frame.width - 120, y: screen.maxY - 8))
            }
            panel.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(3.5))
            // Kept as a fallback, for when the menu bar icon is turned off.
            if !FileManager.default.fileExists(atPath: dir.appending(path: "menubar-\(scheme).png").path) {
                await capture([panel], dir.appending(path: "menubar-\(scheme).png"))
            }
            panel.orderOut(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)

            // One-time codes, then Watchtower with its findings.
            model.requestedSection = .codes
            // Just after the codes change, so their rings are full.
            let into = Date.now.timeIntervalSince1970.truncatingRemainder(dividingBy: 30)
            try? await Task.sleep(for: .seconds(30 - into + 1.5))
            await capture([window], dir.appending(path: "codes-\(scheme).png"))
            model.breachCounts = Dictionary(uniqueKeysWithValues: model.items.compactMap { item in
                DemoVault.breached[item.name].map { (item.id, $0) }
            })
            model.requestedSection = .watchtower
            try? await Task.sleep(for: .seconds(2))
            await capture([window], dir.appending(path: "watchtower-\(scheme).png"))
            model.requestedSection = .section(.all)
            model.selectedID = "2"
            try? await Task.sleep(for: .seconds(1.5))

            // The command palette over it, with a search typed in.
            model.openPalette()
            try? await Task.sleep(for: .seconds(1))
            if let panel = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.level != .normal }) {
                (panel.firstResponder as? NSTextView)?.insertText("git", replacementRange: NSRange(location: NSNotFound, length: 0))
                try? await Task.sleep(for: .seconds(1.5))
                await capture([panel, window], dir.appending(path: "palette-\(scheme).png"))
                panel.orderOut(nil)
            }

            // The password generator.
            model.showingGenerator = true
            try? await Task.sleep(for: .seconds(1.5))
            await capture(NSApp.windows.filter { $0.isVisible && ($0 === window || $0.sheetParent === window) }.reversed(),
                    dir.appending(path: "generator-\(scheme).png"))
            model.showingGenerator = false
            try? await Task.sleep(for: .seconds(1))

            // Locked: the vault door. Locking reloads the saved accounts from disk; put the demo one back at once, so
            // a real account never shows.
            let demoAccounts = model.accounts
            model.lock(animated: false)
            model.setPreviewAccounts(demoAccounts)
            model.phase = .locked
            try? await Task.sleep(for: .seconds(3))
            guard model.accounts.map(\.id) == demoAccounts.map(\.id) else { exit(1) }
            await capture([window], dir.appending(path: "locked-\(scheme).png"))

            // Signing in to a self-hosted server.
            model.setPreviewAccounts([])
            model.serverKind = .selfHosted
            model.serverURL = "https://vault.home.arpa"
            model.email = "alex@example.com"
            model.serverStatus = .reachable(product: "Vaultwarden", version: "2026.6.0")
            model.phase = .login
            // Let the server check give up on the made-up server, then show it as checked.
            try? await Task.sleep(for: .seconds(6))
            model.serverStatus = .reachable(product: "Vaultwarden", version: "2026.6.0")
            try? await Task.sleep(for: .seconds(0.4))
            guard model.accounts.isEmpty else { exit(1) }
            await capture([window], dir.appending(path: "signin-\(scheme).png"))
            print(dir.path)
            exit(0)
        }
    }

    /// Composites the given windows (front first) as the window server shows them, with the app active so the traffic
    /// lights and selections show in colour.
    /// Triwarden's own menu bar button, if its icon is in the menu bar.
    private static func statusButton(_ view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        return view.subviews.lazy.compactMap(statusButton).first
    }

    private static func capture(_ windows: [NSWindow], _ url: URL, activate: Bool = true) async {
        if activate { NSApp.activate(ignoringOtherApps: true) }
        // A lone window becomes key; with several (the palette over the vault) focus stays put, or the palette closes.
        if windows.count == 1, windows[0].canBecomeMain { windows[0].makeKeyAndOrderFront(nil) }
        try? await Task.sleep(for: .seconds(0.6))
        typealias CreateImage = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
        // CGWindowListCreateImageFromArray is hidden from Swift since macOS 15; it still works for an app's own windows.
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImageFromArray") else { return }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        var ids = windows.map { UnsafeRawPointer(bitPattern: UInt($0.windowNumber)) }
        let array = CFArrayCreate(nil, &ids, ids.count, nil)!
        guard let image = create(.null, array, 0)?.takeRetainedValue() else { return }
        do {
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            // Streamed for callers that can't read the app's container (as with snapshots).
            if ProcessInfo.processInfo.environment["TRIWARDEN_SNAPSHOT_STDOUT"] == "1", let png {
                print("SHOT \(url.lastPathComponent) \(png.base64EncodedString())")
                return
            }
            try png?.write(to: url)
            print("shot", url.lastPathComponent, image.width, image.height)
        } catch {
            print("shot failed", url.lastPathComponent, error.localizedDescription)
        }
    }
}
#endif

