# Bank-independent groups of Merchant Category Codes (ISO 18245), used to categorise
# card transactions from any bank connection that reports an MCC (monobank today).
#
# A group is a concept ("groceries", "taxi"), not a Sure category. Each family maps a
# group to one of its own categories: by a stored choice (MccCategoryMapping) or
# automatically by name (Mcc::DefaultMapping, through the English and Ukrainian aliases
# and the fallbacks below). Mcc::CategoryMatcher puts the two together.
#
# How a transaction finds its group (Mcc::Taxonomy.group_for):
#   1. own transfer: description says money moved between the owner's own accounts
#      (jar top-up, currency exchange). Never categorised.
#   2. description pattern: a known brand or wording (Uber, Київстар, "Кешбек") wins
#      over the code, since acquirers often report a generic MCC.
#   3. originalMcc, then mcc: the code table.
#   4. direction: an inflow on a spending group is a refund ("refund" group, or the
#      group's reverse_group, e.g. an incoming money transfer); an outflow on an income
#      group goes to its reverse_group or nowhere.
#
# Codes with no honest single meaning (6012/6051/6540 quasi-cash and e-money top-ups,
# 5993 tobacco) are not in the table: an unmapped transaction stays uncategorised for
# the family's rules and the AI categoriser.
module Mcc
  module Taxonomy
    DIRECTIONS = %i[outflow inflow any].freeze
    OWN_TRANSFER = :own_transfer
    REFUND = :refund

    # key: Symbol; aliases_en / aliases_uk: category names this group matches, best
    # first; mccs: Array<Integer>; mcc_ranges: Array<Range>; direction: :outflow,
    # :inflow or :any; classification: the Category classification the automatic
    # match requires ("expense", "income" or nil for either); description_patterns:
    # Array<Regexp>; skip: no automatic category (own transfers, cash, gambling);
    # fallbacks: group keys whose aliases are tried next by the automatic match;
    # reverse_group: group for a transaction in the other direction (nil = refund for
    # spending groups, none for income groups).
    Group = Data.define(
      :key, :aliases_en, :aliases_uk, :mccs, :mcc_ranges, :direction, :classification,
      :description_patterns, :skip, :fallbacks, :reverse_group
    ) do
      def label
        I18n.t("mcc.groups.#{key}.label", default: key.to_s.humanize)
      end

      def examples
        I18n.t("mcc.groups.#{key}.examples", default: "")
      end

      def aliases
        aliases_en + aliases_uk
      end

      def skip?
        skip
      end

      def includes_mcc?(code)
        mccs.include?(code) || mcc_ranges.any? { |range| range.cover?(code) }
      end

      # A group that a transaction can land in (it has codes or patterns). Groups
      # without either only serve as named fallbacks ("health", "income").
      def matchable?
        mccs.any? || mcc_ranges.any? || description_patterns.any?
      end

      # Shown in settings and storable in MccCategoryMapping.
      def mappable?
        key != OWN_TRANSFER && matchable?
      end

      def matches_description?(text)
        description_patterns.any? { |pattern| pattern.match?(text) }
      end
    end

    class << self
      # Regexp of alternatives (regex fragments) that start at a word boundary and run
      # to one, so "atb" does not match "statbank". Unicode-aware: Ruby's \b does not
      # treat Cyrillic letters as word characters reliably.
      def words(*alternatives)
        Regexp.new("(?<![[:alnum:]])(?:#{alternatives.join("|")})(?![[:alnum:]])", Regexp::IGNORECASE)
      end

      # Like words, but the end of the match may sit inside a word, for stems
      # ("благодійн" matches "благодійний", "благодійність").
      def stems(*alternatives)
        Regexp.new("(?<![[:alnum:]])(?:#{alternatives.join("|")})", Regexp::IGNORECASE)
      end

      # Alternatives at the start of the description.
      def starts(*alternatives)
        Regexp.new("\\A\\s*(?:#{alternatives.join("|")})", Regexp::IGNORECASE)
      end

      private
        def group(key, en:, uk:, mccs: [], ranges: [], direction: :outflow, classification: :auto,
                  patterns: [], skip: false, fallbacks: [], reverse: nil)
          raise ArgumentError, "#{key}: unknown direction #{direction}" unless DIRECTIONS.include?(direction)

          classification = { outflow: "expense", inflow: "income", any: nil }.fetch(direction) if classification == :auto

          Group.new(
            key: key, aliases_en: en.freeze, aliases_uk: uk.freeze, mccs: mccs.freeze,
            mcc_ranges: ranges.freeze, direction: direction, classification: classification,
            description_patterns: patterns.freeze, skip: skip, fallbacks: fallbacks.freeze,
            reverse_group: reverse
          )
        end
    end

    # Order = order in settings, and the order description patterns are tried after
    # PATTERN_PRIORITY.
    GROUPS = [
      # Food
      group(:groceries,
        en: [ "groceries", "grocery", "supermarket", "supermarkets", "food shopping" ],
        uk: [ "продукти", "продукти харчування", "супермаркет", "супермаркети", "бакалія" ],
        # Supermarkets, freezer and meat provisioners, confectionery, dairy, bakeries,
        # convenience and specialty food stores
        mccs: [ 5411, 5422, 5441, 5451, 5462, 5499 ],
        patterns: [
          words("сільпо", "silpo", "атб", "atb", "атб-маркет", "atb-market", "novus", "новус", "varus", "варус",
                "фора", "fora", "ашан", "auchan", "metro cash", "метро кеш", "велика кишеня", "velyka kyshenia",
                "таврія ?в", "tavria ?v", "наш край", "eko ?market", "еко ?маркет", "фуршет", "furshet",
                "близенько", "blyzenko", "рукавичка", "rukavychka", "spar", "спар", "lidl", "biedronka",
                "kaufland", "carrefour", "billa", "żabka", "zabka", "aldi", "rewe")
        ],
        fallbacks: %i[food_and_drinks]),
      group(:eating_out,
        en: [ "eating out", "restaurants", "restaurant", "dining", "dining out", "cafes and restaurants", "cafes", "bars" ],
        uk: [ "кафе та ресторани", "кафе і ресторани", "ресторани та кафе", "ресторани", "ресторан", "кафе",
              "їжа поза домом", "бари" ],
        # Caterers, restaurants, bars and nightclubs
        mccs: [ 5811, 5812, 5813 ],
        patterns: [ stems("ресторан", "restaurant", "пузата хата", "puzata hata"),
                    words("bolt ?food", "uber ?eats", "glovo", "глово", "wolt") ],
        fallbacks: %i[food_and_drinks]),
      group(:coffee,
        en: [ "coffee out", "coffee", "coffee shops", "coffee shop" ],
        uk: [ "кава", "кава поза домом", "кав'ярні", "кав'ярня" ],
        # No code of its own: coffee shops report 5812 or 5814
        patterns: [ stems("кав'?ярн", "кофейн", "coffee", "espresso", "еспресо", "starbucks", "aroma ?kava",
                          "арома ?кава", "costa coffee"),
                    words("кава", "kava") ],
        fallbacks: %i[eating_out food_and_drinks]),
      group(:fast_food,
        en: [ "fast food", "takeaway", "take away", "street food" ],
        uk: [ "фастфуд", "фаст-фуд", "швидка їжа" ],
        mccs: [ 5814 ],
        patterns: [ stems("mcdonald", "макдональд", "burger king", "бургер кінг", "domino'?s", "шаурм", "шаверм",
                          "shawarma"),
                    words("kfc") ],
        fallbacks: %i[eating_out food_and_drinks]),
      group(:food_and_drinks,
        en: [ "food and drinks", "food and drink", "food and beverages", "food", "drinks" ],
        uk: [ "їжа та напої", "їжа і напої", "їжа", "харчування", "напої" ],
        # Package stores: beer, wine and liquor
        mccs: [ 5921 ],
        patterns: [ words("winetime", "вайнтайм", "good wine", "гуд вайн", "алкомаркет") ]),

      # Transport and travel
      group(:taxi,
        en: [ "taxi", "taxis", "cab", "rides", "ride hailing" ],
        uk: [ "таксі" ],
        mccs: [ 4121 ],
        patterns: [ words("uber(?! ?eats)", "bolt(?! ?food)(?! ?drive)", "uklon", "уклон", "opti ?taxi", "оптітаксі",
                          "таксі", "taxi", "shark ?taxi") ],
        fallbacks: %i[transportation]),
      group(:public_transport,
        en: [ "public transport", "public transportation", "transit", "metro", "bus" ],
        uk: [ "громадський транспорт", "проїзд", "метро" ],
        # Local and suburban passenger transport (incl. ferries), bus lines
        mccs: [ 4111, 4131 ],
        patterns: [ stems("метрополітен", "metropoliten", "kyiv ?metro", "київпастранс", "kyivpastrans",
                          "easyway", "транспортна картка", "проїзд"),
                    words("ktoken") ],
        fallbacks: %i[transportation]),
      group(:railways,
        en: [ "railways", "railway", "trains", "train", "rail", "train tickets" ],
        uk: [ "залізниця", "потяги", "поїзди", "укрзалізниця", "квитки на потяг" ],
        # Railroads, passenger railways
        mccs: [ 4011, 4112 ],
        patterns: [ stems("укрзалізниц", "ukrzaliznytsia", "uz\\.gov\\.ua", "інтерсіті", "intercity",
                          "deutsche bahn"),
                    words("pkp") ],
        fallbacks: %i[travel transportation]),
      group(:fuel,
        en: [ "fuel", "gas", "petrol", "gasoline", "gas station" ],
        uk: [ "пальне", "паливо", "бензин", "азс", "заправка" ],
        # Service stations, automated fuel dispensers, fuel dealers, EV charging
        mccs: [ 5541, 5542, 5552, 5983 ],
        patterns: [ words("okko", "окко", "wog", "socar", "сокар", "upg", "shell", "brsm", "брсм", "авантаж",
                          "avantazh", "укрнафта", "ukrnafta", "klo", "amic", "амік", "азс") ],
        fallbacks: %i[car transportation]),
      group(:parking,
        en: [ "parking", "parking and tolls", "tolls" ],
        uk: [ "паркування", "парковка", "паркінг", "стоянка" ],
        # Parking lots and garages, tolls and bridge fees
        mccs: [ 4784, 7523 ],
        patterns: [ stems("parking", "паркінг", "паркуван", "парковк") ],
        fallbacks: %i[car transportation]),
      group(:car_service,
        en: [ "car service", "car maintenance", "car repair", "car care", "auto service", "car wash" ],
        uk: [ "обслуговування авто", "ремонт авто", "автосервіс", "автомийка", "мийка" ],
        # Car and motorcycle dealers, auto supply and parts, tires, body repair, paint,
        # service shops, car washes, towing
        mccs: [ 5511, 5521, 5531, 5532, 5533, 5571, 5592, 5598, 5599, 7531, 7534, 7535, 7538, 7542, 7549 ],
        patterns: [ stems("автомийк", "car ?wash", "шиномонтаж", "автосервіс", "autodoc", "exist\\.ua") ],
        fallbacks: %i[car transportation]),
      group(:travel_air,
        en: [ "flights", "flight", "air travel", "airlines", "air tickets" ],
        uk: [ "авіаквитки", "перельоти", "авіа" ],
        # Airlines (3000-3299 are individual carriers), airlines and air carriers, airports
        mccs: [ 4511, 4582 ],
        ranges: [ 3000..3299 ],
        patterns: [ words("ryanair", "wizz ?air", "skyup", "lufthansa", "turkish airlines", "pegasus", "lot polish airlines",
                          "мау") ],
        fallbacks: %i[travel]),
      group(:lodging,
        en: [ "lodging", "accommodation", "hotels", "hotel" ],
        uk: [ "проживання", "готелі", "готель" ],
        # Hotels (3500-3999 are individual chains), timeshares, camps, campgrounds
        mccs: [ 7011, 7012, 7032, 7033 ],
        ranges: [ 3500..3999 ],
        patterns: [ stems("booking\\.com", "airbnb", "hotel", "готел", "hostel", "хостел") ],
        fallbacks: %i[travel]),
      group(:car_rental,
        en: [ "car rental", "car hire", "rental cars" ],
        uk: [ "оренда авто", "прокат авто" ],
        # Car rental agencies (3351-3441 are individual companies), truck and RV rental
        mccs: [ 7512, 7513, 7519 ],
        ranges: [ 3351..3441 ],
        patterns: [ words("rentalcars", "sixt", "hertz", "avis", "europcar", "getmancar", "bolt ?drive") ],
        fallbacks: %i[travel]),
      group(:travel,
        en: [ "travel", "travelling", "traveling", "trips", "vacation", "holidays" ],
        uk: [ "подорожі", "мандрівки", "відпустка", "туризм" ],
        # Cruise lines, boat rentals, travel agencies and tour operators, transportation
        # services not elsewhere classified
        mccs: [ 4411, 4457, 4722, 4723, 4789 ],
        patterns: [ words("flixbus", "blablacar", "блаблакар", "join ?up", "tripadvisor") ]),
      group(:transportation,
        en: [ "transportation", "transport", "commute" ],
        uk: [ "транспорт", "пересування" ],
        direction: :outflow),
      group(:car,
        en: [ "car", "auto", "vehicle", "car expenses" ],
        uk: [ "авто", "автомобіль", "машина" ],
        direction: :outflow),

      # Health
      group(:pharmacy,
        en: [ "pharmacy", "pharmacies", "drugstore", "medicines", "medication" ],
        uk: [ "аптеки", "аптека", "ліки", "медикаменти" ],
        # Drug stores and pharmacies, drugs and druggists' sundries
        mccs: [ 5122, 5912 ],
        patterns: [ stems("аптек", "apteka", "pharmac", "подорожник", "podorozhnyk", "бажаємо здоров"),
                    words("анц", "anc") ],
        fallbacks: %i[health]),
      group(:medical_services,
        en: [ "medical services", "medical", "doctors", "doctor", "clinic", "clinics", "medical care" ],
        uk: [ "медичні послуги", "медицина", "лікарі", "лікар", "клініка", "клініки", "стоматологія" ],
        # Doctors, dentists, osteopaths, chiropractors, optometrists, opticians,
        # podiatrists, other practitioners, nursing, hospitals, labs, medical services,
        # ambulance, medical equipment, hearing aids, orthopedic goods
        mccs: [ 4119, 5047, 5975, 5976, 8011, 8021, 8031, 8041, 8042, 8043, 8044, 8049, 8050, 8062, 8071, 8099 ],
        patterns: [ stems("добробут", "dobrobut", "медіком", "medikom", "синево", "synevo", "клінік", "clinic",
                          "стоматолог", "dental", "лаборатор", "into-?sana", "оберіг", "oberig"),
                    words("діла", "dila") ],
        fallbacks: %i[health]),
      group(:health,
        en: [ "health", "healthcare", "health care" ],
        uk: [ "здоров'я", "охорона здоров'я" ]),

      # Subscriptions and bills
      group(:streaming,
        en: [ "streaming", "streaming services", "tv", "video streaming", "music streaming" ],
        uk: [ "стрімінг", "стрімінгові сервіси", "телебачення" ],
        # Cable, satellite and other pay television and radio
        mccs: [ 4899 ],
        patterns: [ words("netflix", "spotify", "youtube", "megogo", "мегого", "sweet\\.?tv", "apple music",
                          "apple tv", "deezer", "disney", "hbo", "twitch", "oll\\.?tv", "takflix", "prime ?video",
                          "kyivstar ?tv", "київстар ?тб") ],
        fallbacks: %i[digital_subscriptions entertainment]),
      group(:digital_subscriptions,
        en: [ "subscription services", "subscriptions", "subscription", "digital subscriptions", "online services",
              "software", "apps" ],
        uk: [ "підписки", "підписка", "онлайн-сервіси", "онлайн сервіси", "програми" ],
        # Digital goods: media, applications, large merchants; continuity and
        # subscription merchants
        mccs: [ 5815, 5817, 5818, 5968 ],
        patterns: [ stems("apple\\.com", "itunes", "icloud", "google (?:one|storage|play)", "openai", "chatgpt",
                          "anthropic", "claude\\.ai", "microsoft", "adobe", "dropbox", "notion", "github", "jetbrains",
                          "patreon", "figma", "canva", "1password", "proton", "nordvpn") ]),
      group(:mobile_plan,
        en: [ "mobile plan", "mobile", "phone", "phone plan", "mobile phone", "cell phone", "mobile top up" ],
        uk: [ "мобільний зв'язок", "мобільний", "зв'язок", "телефон", "поповнення мобільного" ],
        # Telecommunication services (incl. prepaid top-ups), key-entry telecom merchants
        mccs: [ 4813, 4814 ],
        patterns: [ stems("київстар", "kyivstar", "vodafone", "водафон", "lifecell", "лайфсел", "поповнення мобільного",
                          "mobile top", "3mob", "тримоб") ],
        fallbacks: %i[utilities]),
      group(:internet,
        en: [ "internet", "home internet", "broadband", "internet provider" ],
        uk: [ "інтернет", "домашній інтернет" ],
        # Computer network and information services
        mccs: [ 4816 ],
        patterns: [ words("воля", "volia", "тріолан", "triolan", "ланет", "lanet", "датагруп", "datagroup",
                          "укртелеком", "ukrtelecom", "фрінет", "freenet") ],
        fallbacks: %i[utilities]),
      group(:utilities,
        en: [ "utilities", "utility bills", "bills", "housing and utilities", "communal services" ],
        uk: [ "комунальні послуги", "комунальні платежі", "комунальні", "комуналка" ],
        # Electric, gas, water and sanitary utilities
        mccs: [ 4900 ],
        patterns: [ stems("комунальн", "yasno", "ясно енерг", "нафтогаз", "naftogaz", "газопостач", "газмереж",
                          "водоканал", "vodokanal", "теплоенерго", "teploenergo", "енергозбут", "київенерго",
                          "kyivenergo", "дтек", "dtek"),
                    words("осбб", "osbb") ]),
      group(:rent,
        en: [ "rent", "mortgage rent", "rent and mortgage", "housing", "apartment rent", "mortgage" ],
        uk: [ "оренда", "оренда житла", "оренда квартири", "квартплата", "іпотека" ],
        # Real estate agents and managers: rentals
        mccs: [ 6513 ],
        patterns: [ stems("оренда (?:житла|квартири)", "rent payment") ]),

      # Leisure
      group(:gym,
        en: [ "gym", "fitness", "fitness club", "gym membership", "workout" ],
        uk: [ "спортзал", "тренажерний зал", "фітнес", "зал" ],
        # Membership clubs: sports, recreation, athletic
        mccs: [ 7997 ],
        patterns: [ stems("sport ?life", "спорт ?лайф", "fitness", "фітнес", "smart ?gym", "bio ?tonus"),
                    words("gym", "apollo") ],
        fallbacks: %i[sports]),
      group(:sports,
        en: [ "sports", "sport", "sports and fitness", "sporting goods", "sports gear" ],
        uk: [ "спорт", "спорттовари", "спортивні товари" ],
        # Bicycle shops, sporting goods, sports clubs and fields, golf courses
        mccs: [ 5940, 5941, 7941, 7992 ],
        patterns: [ words("decathlon", "декатлон", "intersport", "інтерспорт", "megasport", "мегаспорт") ]),
      group(:entertainment,
        en: [ "entertainment", "leisure", "fun", "hobbies", "hobby", "games", "movies", "concerts", "going out" ],
        uk: [ "розваги", "дозвілля", "хобі", "ігри", "кіно", "концерти" ],
        # Music and record stores, digital games, film distribution, cinemas, video
        # rental, dance halls, theatre tickets, bands, billiards, bowling, attractions,
        # arcades, amusement parks, aquariums, recreation services
        mccs: [ 5733, 5735, 5816, 7829, 7832, 7841, 7911, 7922, 7929, 7932, 7933, 7991, 7993, 7994, 7996, 7998, 7999 ],
        patterns: [ stems("multiplex", "мультиплекс", "планета кіно", "planeta kino", "karabas", "карабас",
                          "concert\\.ua", "steam(?:powered|games)?", "playstation", "xbox", "nintendo", "кінотеатр",
                          "cinema", "театр", "theatre", "museum", "музей", "epic games", "ticketmaster"),
                    words("oscar", "оскар") ]),
      group(:education,
        en: [ "education", "learning", "courses", "school", "tuition", "studies" ],
        uk: [ "освіта", "навчання", "курси", "школа", "університет" ],
        # Schools, colleges, correspondence, business and vocational schools
        mccs: [ 8211, 8220, 8241, 8244, 8249, 8299 ],
        patterns: [ stems("coursera", "udemy", "prometheus", "прометеус", "duolingo", "mate academy", "hillel",
                          "goit", "englishdom", "preply", "projector") ]),
      group(:books,
        en: [ "books", "book", "reading", "magazines" ],
        uk: [ "книги", "книжки", "книгарня", "література" ],
        # Book stores, news dealers, publishing and printing, books and periodicals
        mccs: [ 2741, 5192, 5942, 5994 ],
        patterns: [ stems("yakaboo", "якабу", "книгарн", "книжков", "наш формат", "nashformat", "bookling",
                          "readeat", "vivat", "віват") ],
        fallbacks: %i[education entertainment shopping]),

      # Shopping
      group(:clothing,
        en: [ "clothing", "clothes", "apparel", "fashion", "shoes", "footwear" ],
        uk: [ "одяг", "одяг і взуття", "одяг та взуття", "взуття" ],
        # Men's, women's, children's and family clothing, accessories, sportswear,
        # shoes, furriers, tailors, wigs, misc apparel, costume rental
        mccs: [ 5611, 5621, 5631, 5641, 5651, 5655, 5661, 5681, 5691, 5697, 5698, 5699, 7296 ],
        patterns: [ words("zara", "h&m", "reserved", "lc ?waikiki", "uniqlo", "answear", "intertop", "інтертоп",
                          "sinsay", "bershka", "pull ?& ?bear", "massimo dutti", "stradivarius", "mango",
                          "colin'?s", "cropp", "mohito", "defacto") ],
        fallbacks: %i[shopping]),
      group(:electronics,
        en: [ "electronics", "gadgets", "tech", "technology", "computers", "appliances" ],
        uk: [ "електроніка", "техніка", "гаджети", "побутова техніка" ],
        # Telephone sales, computers and software (B2B), household appliances,
        # electronics, software stores, camera stores, electronics and computer repair
        mccs: [ 4812, 5045, 5722, 5732, 5734, 5946, 7379, 7622 ],
        patterns: [ words("comfy", "комфі", "фокстрот", "foxtrot", "eldorado", "ельдорадо", "алло", "allo",
                          "цитрус", "citrus", "moyo", "мойо", "istore", "ябко", "yabko") ],
        fallbacks: %i[shopping]),
      group(:home,
        en: [ "home", "household", "home improvement", "home and garden", "furniture", "house" ],
        uk: [ "дім", "для дому", "товари для дому", "господарство", "ремонт", "меблі", "побут" ],
        # Building contractors and trades, home supply, lumber, paint, hardware,
        # garden, furniture, floor covering, drapery, fireplaces, home furnishings,
        # glassware, pest control, cleaning, furniture repair, welding, repair shops
        mccs: [ 1520, 1711, 1731, 1740, 1750, 1761, 1771, 1799, 5200, 5211, 5231, 5251, 5261, 5712, 5713, 5714,
                5718, 5719, 5950, 7342, 7349, 7641, 7692, 7699 ],
        patterns: [ words("епіцентр", "epicentr", "ikea", "ікея", "jysk", "юск", "leroy merlin", "нова лінія",
                          "nova liniya", "аврора", "avrora") ],
        fallbacks: %i[shopping]),
      group(:beauty,
        en: [ "beauty", "personal care", "cosmetics", "hair", "haircut", "barber", "self care" ],
        uk: [ "краса", "догляд", "косметика", "перукарня", "барбершоп", "салон краси" ],
        # Cosmetic stores, barber and beauty shops, massage, spas
        mccs: [ 5977, 7230, 7297, 7298 ],
        patterns: [ stems("prostor", "простор", "watsons", "makeup\\.com", "notino", "barbershop", "барбершоп",
                          "салон краси", "перукарн", "brocard", "брокард"),
                    words("eva") ],
        fallbacks: %i[shopping]),
      group(:pets,
        en: [ "pets", "pet", "pet care", "pet supplies", "vet", "veterinary" ],
        uk: [ "тварини", "домашні тварини", "улюбленці", "зоотовари", "ветеринар" ],
        # Veterinary services, pet shops
        mccs: [ 742, 5995 ],
        patterns: [ stems("зоомагаз", "masterzoo", "мастерзоо", "ветклінік", "vet ?clinic", "petslike", "зоотовар") ],
        fallbacks: %i[shopping]),
      group(:kids,
        en: [ "kids", "children", "child", "baby", "childcare", "toys" ],
        uk: [ "діти", "дитячі товари", "дитина", "іграшки", "дитсадок" ],
        # Hobby, toy and game shops; child care services
        mccs: [ 5945, 8351 ],
        patterns: [ stems("антошка", "antoshka", "будинок іграшок", "smyk", "дитячий світ") ],
        fallbacks: %i[shopping]),
      group(:delivery,
        en: [ "delivery", "shipping", "postal services", "post", "couriers", "parcels" ],
        uk: [ "доставка", "пошта", "поштові послуги", "кур'єр" ],
        # Courier services, postal services
        mccs: [ 4215, 9402 ],
        patterns: [ stems("нова пошта", "nova ?poshta", "novapost", "укрпошта", "ukrposhta", "meest", "міст експрес") ],
        fallbacks: %i[services]),
      group(:services,
        en: [ "services", "personal services", "professional services" ],
        uk: [ "послуги", "побутові послуги", "професійні послуги" ],
        # Laundry, dry cleaning, carpet cleaning, photo studios, shoe repair, funeral,
        # tax preparation, counselling, misc personal services, advertising, copying,
        # employment agencies, consulting, security, equipment rental, business
        # services, legal, accounting, professional services, small appliance and
        # watch repair
        mccs: [ 7210, 7211, 7216, 7217, 7221, 7251, 7261, 7276, 7277, 7299, 7311, 7333, 7338, 7361, 7392, 7393,
                7394, 7395, 7399, 7629, 7631, 8111, 8931, 8999 ],
        patterns: [ stems("хімчистк", "пральн", "laundry", "нотаріус", "notary") ]),
      group(:shopping,
        en: [ "shopping", "purchases", "retail", "online shopping" ],
        uk: [ "покупки", "шопінг", "магазини", "онлайн-покупки" ],
        # Marketplaces, wholesale clubs, duty free, discount, department and variety
        # stores, general merchandise, used and antique goods, pawn shops, jewellery,
        # stationery, gifts, luggage, fabric, catalogue and direct marketing, arts and
        # crafts, collectibles, religious goods, florists, misc specialty retail
        mccs: [ 5262, 5300, 5309, 5310, 5311, 5331, 5399, 5931, 5932, 5933, 5937, 5943, 5944, 5947, 5948, 5949,
                5964, 5965, 5969, 5970, 5971, 5972, 5973, 5978, 5992, 5996, 5997, 5998, 5999 ],
        patterns: [ stems("rozetka", "розетка", "prom\\.ua", "aliexpress", "amazon", "ebay", "temu", "allegro",
                          "kasta"),
                    words("olx") ]),

      # Giving and the state
      group(:charity,
        en: [ "charity", "charities", "donations", "donation", "gifts and donations", "giving" ],
        uk: [ "благодійність", "донати", "пожертви", "благодійні внески" ],
        # Charitable and social service organisations, civic and fraternal
        # associations, religious organisations
        mccs: [ 8398, 8641, 8661 ],
        patterns: [ stems("благодійн", "charity", "donat", "донат", "united ?24", "червоний хрест", "red cross",
                          "unicef", "таблеточки", "tabletochki") ]),
      group(:military_support,
        en: [ "military", "military support", "army", "army support", "military donations", "armed forces", "defence",
              "defense" ],
        uk: [ "зсу", "армія", "військо", "допомога армії", "допомога зсу", "донати на зсу", "військові" ],
        # No code of its own: funds report 8398
        patterns: [ stems("повернись живим", "come back alive", "savelife", "притул", "prytula", "армія дронів",
                          "army of drones", "госпітальєр", "hospitallers", "стерненк", "sternenko", "летючі",
                          "збір на (?:дрон|авто|пікап|зсу|бригад|батальйон|полк|військ|фронт|тепловізор|старлінк|starlink|мавік|mavic|fpv|рер)",
                          "на (?:дрони|зсу|фронт)(?![[:alnum:]])"),
                    words("зсу", "азов", "azov", "3 ?ошбр", "третя штурмова", "kolo") ],
        fallbacks: %i[charity]),
      group(:taxes,
        en: [ "taxes", "tax", "tax payments", "income tax" ],
        uk: [ "податки", "податок", "єдиний податок", "єсв" ],
        mccs: [ 9311 ],
        patterns: [ stems("податк", "податок", "військовий збір", "tax payment"),
                    words("єсв", "пдфо", "дпс") ]),
      group(:government_fees,
        en: [ "government fees", "government", "government services", "public services", "state fees", "fines",
              "duties" ],
        uk: [ "державні послуги", "держпослуги", "штрафи", "державне мито", "мито", "адміністративні послуги" ],
        # Court costs, fines, bail and bond, government services, intra-government
        # purchases
        mccs: [ 9211, 9222, 9223, 9399, 9405 ],
        patterns: [ stems("держмито", "державне мито", "судовий збір", "штраф(?! за прострочення)", "паспортн",
                          "цнап", "сервісний центр мвс", "гсц мвс"),
                    words("дія", "diia") ],
        fallbacks: %i[taxes]),
      group(:insurance,
        en: [ "insurance", "insurances" ],
        uk: [ "страхування", "страховка", "страхові" ],
        # Insurance sales, underwriting and premiums; direct marketing insurance
        mccs: [ 5960, 6300, 6381, 6399 ],
        patterns: [ stems("страхув", "страхов", "осцпв", "insurance", "uniqa", "уніка", "оранта"),
                    words("arx", "ingo", "інго") ]),

      # Bank movements
      group(:bank_fees,
        en: [ "fees", "bank fees", "fees and charges", "banking fees", "commissions", "commission", "service fees",
              "charges" ],
        uk: [ "комісії", "комісія", "банківські комісії", "банківські послуги", "обслуговування" ],
        # No code: banks book fees with their own descriptions
        patterns: [ starts("комісія"),
                    stems("комісія за", "плата за (?:обслуговування|випуск|перевипуск|користування|смс|sms)",
                          "обслуговування (?:картки|рахунку)", "штраф за прострочення"),
                    words("commission", "fee", "fees") ]),
      group(:interest,
        en: [ "interest", "interest income", "interest earned", "savings interest", "deposit interest" ],
        uk: [ "відсотки", "проценти", "відсотки за депозитом", "відсотковий дохід" ],
        direction: :inflow,
        # Interest paid on a credit card is a fee
        reverse: :bank_fees,
        patterns: [ stems("відсотк", "процент(?:и|ів) (?:на|за)", "нарахування процент", "дохід за депозит",
                          "interest") ],
        fallbacks: %i[income]),
      group(:cashback,
        en: [ "cashback", "cash back", "rewards", "bonuses" ],
        uk: [ "кешбек", "кешбеки", "кешбек та бонуси", "бонуси" ],
        direction: :inflow,
        patterns: [ stems("кешбек", "кешбэк", "кэшбэк", "cash ?back") ],
        fallbacks: %i[income]),
      group(:salary,
        en: [ "salary", "salaries", "wages", "wage", "paycheck", "payroll" ],
        uk: [ "зарплата", "заробітна плата", "зарплатня", "оклад" ],
        direction: :inflow,
        patterns: [ stems("зарплат", "заробітн", "salary", "payroll", "з/п") ],
        fallbacks: %i[income]),
      group(:income,
        en: [ "income", "other income", "earnings", "revenue" ],
        uk: [ "дохід", "доходи", "надходження", "інші доходи" ],
        direction: :inflow),
      group(:refund,
        en: [ "refund", "refunds", "returns", "reimbursement", "reimbursements" ],
        uk: [ "повернення", "повернення коштів", "відшкодування" ],
        direction: :inflow,
        # A refund may go to an income category or back to an expense one
        classification: nil,
        patterns: [ stems("повернення", "refund", "reversal", "відшкодуван") ]),
      group(:p2p_incoming,
        en: [ "p2p incoming", "incoming p2p", "incoming transfers", "transfers in", "received transfers", "money received" ],
        uk: [ "вхідні перекази", "перекази вхідні", "отримані перекази", "надходження від людей" ],
        direction: :inflow,
        reverse: :p2p_outgoing,
        # monobank writes "Від: Олена К." for a card-to-card transfer in
        patterns: [ starts("від:", "від ", "from:"), stems("переказ від", "зарахування переказу") ]),
      group(:p2p_outgoing,
        en: [ "p2p outgoing", "outgoing p2p", "outgoing transfers", "transfers out", "sent transfers", "money sent" ],
        uk: [ "вихідні перекази", "перекази вихідні", "надіслані перекази", "перекази людям" ],
        reverse: :p2p_incoming,
        # Money transfer; MoneySend intracountry, intercountry and funding
        mccs: [ 4829, 6536, 6537, 6538 ],
        patterns: [ starts("переказ на ", "переказ через ", "to:") ]),

      # Not categorised by default
      group(:cash_withdrawal,
        en: [ "cash", "cash withdrawal", "cash withdrawals", "atm" ],
        uk: [ "готівка", "зняття готівки", "банкомат" ],
        direction: :any,
        skip: true,
        # Manual and automated cash disbursements
        mccs: [ 6010, 6011 ],
        patterns: [ stems("банкомат", "зняття готівки", "видача готівки", "cash withdrawal"), words("atm") ]),
      group(:gambling,
        en: [ "gambling", "betting", "casino", "lottery" ],
        uk: [ "азартні ігри", "ставки", "казино", "лотерея" ],
        direction: :any,
        skip: true,
        # Betting and casinos, government lotteries, online casinos, racing
        mccs: [ 7800, 7801, 7802, 7995, 9406 ],
        patterns: [ stems("parimatch", "парімач", "favbet", "фавбет", "cosmolot", "космолот", "vbet", "pin-?up",
                          "slots city", "slotscity") ]),
      group(OWN_TRANSFER,
        en: [ "own transfers", "transfers between own accounts" ],
        uk: [ "перекази між своїми рахунками", "власні перекази" ],
        direction: :any,
        skip: true,
        # Jar top-ups and withdrawals, transfers between own cards and currency
        # accounts, currency exchange
        patterns: [ starts("на банку", "з банки", "поповнення банки", "з (?:гривнев|доларов|євров)\\S* рахунк",
                           "на (?:гривнев|доларов|євров)\\S* рахунок", "з (?:білої|чорної|залізної|платинової) картки",
                           "на (?:білу|чорну|залізну|платинову) картку", "з рахунку фоп", "на рахунок фоп",
                           "to jar", "from jar"),
                    stems("переказ між (?:власними|своїми) рахунками", "між (?:власними|своїми) рахунками",
                          "купівля валюти", "продаж валюти", "обмін валюти", "transfer between own accounts",
                          "currency exchange") ])
    ].freeze

    # Groups whose description patterns are tried before the rest, in this order:
    # wording that says what kind of movement it is beats a merchant name in the same
    # text ("Повернення коштів Uber", "Військовий збір", "Комісія за переказ").
    # The P2P prefixes ("Від: Олена К.") come before merchant names, so a sender
    # whose name looks like a brand is still a transfer.
    PATTERN_PRIORITY = %i[
      cash_withdrawal refund cashback interest salary taxes government_fees bank_fees military_support charity
      p2p_incoming p2p_outgoing
    ].freeze

    BY_KEY = GROUPS.index_by { |group| group.key.to_s }.freeze

    class << self
      def groups
        GROUPS
      end

      # Groups shown in settings and storable in MccCategoryMapping.
      def mappable_groups
        @mappable_groups ||= GROUPS.select(&:mappable?).freeze
      end

      def mappable_keys
        @mappable_keys ||= mappable_groups.map { |group| group.key.to_s }.freeze
      end

      def find(key)
        return key if key.is_a?(Group)

        BY_KEY[key.to_s]
      end

      # The group for an MCC code alone, or nil.
      def group_for_mcc(mcc)
        code = parse_mcc(mcc)
        code && groups_by_mcc[code]
      end

      # True when the description says the money moved between the owner's own
      # accounts (jar, currency exchange, own card). The bank connection also checks
      # the counterparty IBAN against the owner's own accounts.
      def own_transfer?(description:)
        text = normalize_description(description)
        return false if text.empty?

        find(OWN_TRANSFER).matches_description?(text)
      end

      # @param mcc [Integer, String, nil] the code the bank reports
      # @param original_mcc [Integer, String, nil] the acquirer's code, when the bank
      #   rewrote it (monobank's originalMcc)
      # @param amount [Numeric] Sure-signed: positive = outflow (spending)
      # @param description [String, nil]
      # @return [Group, nil] the own_transfer group for own transfers
      def group_for(mcc:, original_mcc: nil, amount:, description: nil)
        text = normalize_description(description)
        return find(OWN_TRANSFER) if !text.empty? && find(OWN_TRANSFER).matches_description?(text)

        group = group_for_description(text) || group_for_mcc(original_mcc) || group_for_mcc(mcc)
        group && apply_direction(group, amount)
      end

      private
        def groups_by_mcc
          @groups_by_mcc ||= GROUPS.each_with_object({}) do |group, map|
            (group.mccs + group.mcc_ranges.flat_map(&:to_a)).each { |code| map[code] ||= group }
          end.freeze
        end

        def pattern_groups
          @pattern_groups ||= begin
            prioritized = PATTERN_PRIORITY.map { |key| find(key) }
            rest = GROUPS.reject { |group| group.key == OWN_TRANSFER || prioritized.include?(group) }
            (prioritized + rest).select { |group| group.description_patterns.any? }.freeze
          end
        end

        def group_for_description(text)
          return nil if text.empty?

          pattern_groups.find { |group| group.matches_description?(text) }
        end

        def apply_direction(group, amount)
          return group if group.skip? || group.direction == :any

          value = amount.respond_to?(:to_d) ? amount.to_d : 0
          inflow = value.negative?
          outflow = value.positive?

          if group.direction == :outflow && inflow
            find(group.reverse_group || REFUND)
          elsif group.direction == :inflow && outflow
            group.reverse_group && find(group.reverse_group)
          else
            group
          end
        end

        def parse_mcc(mcc)
          return nil if mcc.blank?

          code = Integer(mcc.to_s.strip, 10, exception: false)
          code if code&.positive?
        end

        # Same apostrophe for every keyboard (кав'ярня, кавʼярня, кав’ярня), one space.
        def normalize_description(description)
          description.to_s.unicode_normalize(:nfkc).tr("ʼ’`´", "'").squish
        end
    end
  end
end
