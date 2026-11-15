require "test_helper"

class Mcc::TaxonomyTest < ActiveSupport::TestCase
  REQUIRED_KEYS = %i[
    groceries eating_out coffee fast_food food_and_drinks taxi public_transport railways fuel parking car_service
    travel_air lodging car_rental travel pharmacy medical_services health streaming digital_subscriptions
    mobile_plan utilities internet rent gym sports clothing electronics home beauty shopping education books
    entertainment pets kids charity military_support government_fees taxes insurance bank_fees interest cashback
    salary refund p2p_incoming p2p_outgoing cash_withdrawal own_transfer gambling
  ].freeze

  def group_key(mcc: nil, original_mcc: nil, amount: 100, description: nil)
    Mcc::Taxonomy.group_for(mcc: mcc, original_mcc: original_mcc, amount: amount, description: description)&.key
  end

  test "has every group the plan requires" do
    assert_empty REQUIRED_KEYS - Mcc::Taxonomy.groups.map(&:key)
  end

  test "every group has an English and a Ukrainian alias" do
    Mcc::Taxonomy.groups.each do |group|
      assert group.aliases_en.any?, "#{group.key} has no English alias"
      assert group.aliases_uk.any?, "#{group.key} has no Ukrainian alias"
      assert group.aliases_uk.all? { |name| name.match?(/\p{Cyrillic}/) }, "#{group.key} has a Ukrainian alias without Cyrillic"
    end
  end

  test "every group has an English label and examples" do
    Mcc::Taxonomy.groups.each do |group|
      assert I18n.exists?("mcc.groups.#{group.key}.label", :en), "#{group.key} has no label"
      assert I18n.exists?("mcc.groups.#{group.key}.examples", :en), "#{group.key} has no examples"
    end
  end

  test "no MCC belongs to two groups" do
    owners = Hash.new { |hash, code| hash[code] = [] }
    Mcc::Taxonomy.groups.each do |group|
      (group.mccs + group.mcc_ranges.flat_map(&:to_a)).each { |code| owners[code] << group.key }
    end

    assert_empty owners.select { |_, keys| keys.size > 1 }
  end

  test "no alias names two groups" do
    owners = Hash.new { |hash, name| hash[name] = Set.new }
    Mcc::Taxonomy.groups.each do |group|
      group.aliases.each { |name| owners[Mcc::DefaultMapping.normalize(name)] << group.key }
    end

    assert_empty owners.select { |_, keys| keys.size > 1 }
  end

  test "fallbacks and reverse groups name real groups" do
    Mcc::Taxonomy.groups.each do |group|
      (group.fallbacks + [ group.reverse_group ]).compact.each do |key|
        assert Mcc::Taxonomy.find(key), "#{group.key} points at unknown group #{key}"
      end
    end
  end

  test "mappable groups leave out own transfers and fallback-only groups" do
    keys = Mcc::Taxonomy.mappable_keys

    assert_not_includes keys, "own_transfer"
    assert_not_includes keys, "health"
    assert_not_includes keys, "income"
    assert_includes keys, "cash_withdrawal"
    assert_includes keys, "gambling"
    assert_includes keys, "groceries"
  end

  test "ISO 18245 ranges: airlines, car rental, lodging" do
    assert_equal :travel_air, group_key(mcc: 3000)
    assert_equal :travel_air, group_key(mcc: 3299)
    assert_nil group_key(mcc: 3300)
    assert_equal :car_rental, group_key(mcc: 3351)
    assert_equal :car_rental, group_key(mcc: 3441)
    assert_nil group_key(mcc: 3442)
    assert_equal :lodging, group_key(mcc: 3500)
    assert_equal :lodging, group_key(mcc: 3999)
  end

  test "maps common codes" do
    {
      5411 => :groceries, 5499 => :groceries, 5812 => :eating_out, 5813 => :eating_out, 5814 => :fast_food,
      5921 => :food_and_drinks, 4121 => :taxi, 4111 => :public_transport, 4131 => :public_transport,
      4112 => :railways, 5541 => :fuel, 5542 => :fuel, 7523 => :parking, 7538 => :car_service, 7542 => :car_service,
      4511 => :travel_air, 7011 => :lodging, 7512 => :car_rental, 4722 => :travel, 5912 => :pharmacy,
      8011 => :medical_services, 8021 => :medical_services, 4899 => :streaming, 5815 => :digital_subscriptions,
      5817 => :digital_subscriptions, 5818 => :digital_subscriptions, 4814 => :mobile_plan, 4816 => :internet,
      4900 => :utilities, 6513 => :rent, 7997 => :gym, 5941 => :sports, 5651 => :clothing, 5661 => :clothing,
      5732 => :electronics, 5200 => :home, 5712 => :home, 7230 => :beauty, 5977 => :beauty, 5311 => :shopping,
      5999 => :shopping, 8220 => :education, 5942 => :books, 7832 => :entertainment, 5816 => :entertainment,
      5995 => :pets, 742 => :pets, 5945 => :kids, 8398 => :charity, 9399 => :government_fees, 9222 => :government_fees,
      9311 => :taxes, 6300 => :insurance, 4829 => :p2p_outgoing, 6011 => :cash_withdrawal, 6010 => :cash_withdrawal,
      7995 => :gambling, 4215 => :delivery, 7210 => :services
    }.each do |code, key|
      assert_equal key, group_key(mcc: code), "MCC #{code}"
    end
  end

  test "leaves quasi-cash and unknown codes unmapped" do
    [ 6012, 6051, 6540, 5993, 1234, 0 ].each { |code| assert_nil group_key(mcc: code), "MCC #{code}" }
  end

  test "accepts string codes and ignores blank or malformed ones" do
    assert_equal :groceries, group_key(mcc: "5411")
    assert_equal :groceries, group_key(mcc: " 5411 ")
    assert_nil group_key(mcc: nil)
    assert_nil group_key(mcc: "")
    assert_nil group_key(mcc: "abc")
  end

  test "original MCC wins over the MCC the bank rewrote, and the MCC is the fallback" do
    assert_equal :groceries, group_key(mcc: 4829, original_mcc: 5411)
    assert_equal :p2p_outgoing, group_key(mcc: 4829, original_mcc: 1234)
    assert_equal :p2p_outgoing, group_key(mcc: 4829, original_mcc: nil)
  end

  test "description patterns win over the code" do
    assert_equal :taxi, group_key(mcc: 5999, description: "UKLON")
    assert_equal :taxi, group_key(mcc: 4789, description: "Bolt.eu/O/2411151234")
    assert_equal :taxi, group_key(mcc: 4121, description: "UBER *TRIP")
    assert_equal :taxi, group_key(description: "Таксі 838")
    assert_equal :eating_out, group_key(mcc: 5814, description: "Bolt Food")
    assert_equal :eating_out, group_key(mcc: 5812, description: "Uber Eats")
    assert_equal :groceries, group_key(mcc: 5999, description: "Сільпо")
    assert_equal :groceries, group_key(description: "АТБ-Маркет")
    assert_equal :coffee, group_key(mcc: 5814, description: "Aroma Kava")
    assert_equal :coffee, group_key(mcc: 5812, description: "Кавʼярня Чашка")
    assert_equal :streaming, group_key(mcc: 5815, description: "Netflix.com")
    assert_equal :streaming, group_key(mcc: 5818, description: "MEGOGO")
    assert_equal :streaming, group_key(description: "Spotify P2F4")
    assert_equal :digital_subscriptions, group_key(mcc: 5818, description: "APPLE.COM/BILL")
    assert_equal :mobile_plan, group_key(mcc: 4812, description: "Київстар")
    assert_equal :mobile_plan, group_key(description: "lifecell")
    assert_equal :mobile_plan, group_key(description: "Vodafone Україна")
    assert_equal :fuel, group_key(mcc: 5999, description: "ОККО")
    assert_equal :pharmacy, group_key(mcc: 5999, description: "Аптека Подорожник")
    assert_equal :military_support, group_key(mcc: 8398, description: "Повернись живим")
    assert_equal :military_support, group_key(mcc: 4829, description: "Фонд Сергія Притули")
    assert_equal :military_support, group_key(description: "Збір на дрони для бригади")
    assert_equal :charity, group_key(mcc: 4829, description: "Благодійний фонд Таблеточки")
    assert_equal :bank_fees, group_key(description: "Комісія за переказ")
    assert_equal :bank_fees, group_key(description: "Плата за обслуговування рахунку")
    assert_equal :taxes, group_key(description: "Сплата податку ЄСВ")
    assert_equal :utilities, group_key(description: "YASNO Київ")
  end

  test "movement wording beats a merchant name" do
    assert_equal :taxes, group_key(description: "Військовий збір")
    assert_equal :refund, group_key(mcc: 4121, amount: -150, description: "Повернення коштів Uber")
    assert_equal :p2p_incoming, group_key(mcc: 4829, amount: -500, description: "Від: Єва П.")
    assert_equal :salary, group_key(amount: -40_000, description: "Зарахування заробітної плати")
    assert_equal :cashback, group_key(amount: -120, description: "Виведення кешбеку")
    assert_equal :interest, group_key(amount: -35, description: "Нарахування відсотків")
  end

  test "an inflow on a spending group is a refund" do
    assert_equal :refund, group_key(mcc: 5411, amount: -50)
    assert_equal :refund, group_key(mcc: 5999, amount: -50, description: "Сільпо")
  end

  test "money transfers follow the direction" do
    assert_equal :p2p_outgoing, group_key(mcc: 4829, amount: 500, description: "Олена К.")
    assert_equal :p2p_incoming, group_key(mcc: 4829, amount: -500, description: "Олена К.")
    assert_equal :p2p_outgoing, group_key(mcc: 4829, amount: 500, description: "Від: Олена К.")
  end

  test "an outflow on an income group goes to its reverse group or nowhere" do
    assert_equal :bank_fees, group_key(amount: 30, description: "Відсотки за користування кредитом")
    assert_nil group_key(amount: 20, description: "Кешбек")
    assert_nil group_key(amount: 1_000, description: "Зарплата")
    assert_nil group_key(amount: 100, description: "Повернення боргу")
  end

  test "skipped groups keep their group in both directions, and zero amounts keep the group" do
    assert_equal :cash_withdrawal, group_key(mcc: 6011, amount: 1_000)
    assert_equal :cash_withdrawal, group_key(mcc: 6011, amount: -1_000)
    assert_equal :gambling, group_key(mcc: 7995, amount: -500)
    assert_equal :groceries, group_key(mcc: 5411, amount: 0)
    assert_equal :groceries, group_key(mcc: 5411, amount: nil)
    assert_equal :groceries, group_key(mcc: 5411, amount: "12.50")
  end

  test "own transfers are recognised before anything else" do
    [
      "На банку «Відпустка»", "З банки «Відпустка»", "Поповнення банки «На машину»",
      "Переказ між власними рахунками", "Купівля валюти", "Продаж валюти", "Обмін валюти",
      "З доларового рахунку", "На гривневий рахунок", "З білої картки", "З рахунку ФОП",
      "Transfer between own accounts"
    ].each do |description|
      assert Mcc::Taxonomy.own_transfer?(description: description), description
      assert_equal :own_transfer, group_key(mcc: 4829, amount: 100, description: description), description
      assert_equal :own_transfer, group_key(mcc: 4829, amount: -100, description: description), description
    end
  end

  test "ordinary descriptions are not own transfers" do
    [ nil, "", "Сільпо", "Від: Олена К.", "Переказ на картку", "Банкомат" ].each do |description|
      assert_not Mcc::Taxonomy.own_transfer?(description: description), description.inspect
    end
  end

  test "word boundaries keep short brand names from matching inside other words" do
    assert_nil group_key(description: "Statbank")
    assert_nil group_key(description: "Wogan Street")
    assert_equal :fuel, group_key(description: "WOG АЗС 12")
  end

  test "find accepts symbols, strings and groups" do
    group = Mcc::Taxonomy.find(:groceries)

    assert_equal group, Mcc::Taxonomy.find("groceries")
    assert_equal group, Mcc::Taxonomy.find(group)
    assert_nil Mcc::Taxonomy.find(:nope)
    assert_equal "Groceries", group.label
  end
end
