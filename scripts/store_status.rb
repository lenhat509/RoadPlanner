#!/usr/bin/env ruby
# frozen_string_literal: true

# Read-only check of where the app stands on the App Store, from two independent sources:
#
# 1. App Store Connect (with the App Store Connect API key): the app record, every App Store
#    version and its state, the countries it is available in (and why not, where it isn't), and
#    its price.
# 2. The public App Store: Apple's lookup service in every country, and the product page.
#
# Run by the "Store status" workflow; changes nothing. Needs ASC_KEY_ID, ASC_ISSUER_ID,
# ASC_KEY_CONTENT (base64 .p8) and WAYSTAGE_BUNDLE_ID.
require "json"
require "net/http"
require "uri"
require "spaceship"

ASC = "https://api.appstoreconnect.apple.com"

# App Store Connect names territories by ISO 3166 alpha-3 codes; the public store by alpha-2.
ALPHA2 = <<~CODES.split.to_h { |pair| pair.split(":") }
  ABW:AW AFG:AF AGO:AO AIA:AI ALA:AX ALB:AL AND:AD ARE:AE ARG:AR ARM:AM ASM:AS ATA:AQ ATF:TF
  ATG:AG AUS:AU AUT:AT AZE:AZ BDI:BI BEL:BE BEN:BJ BES:BQ BFA:BF BGD:BD BGR:BG BHR:BH BHS:BS
  BIH:BA BLM:BL BLR:BY BLZ:BZ BMU:BM BOL:BO BRA:BR BRB:BB BRN:BN BTN:BT BVT:BV BWA:BW CAF:CF
  CAN:CA CCK:CC CHE:CH CHL:CL CHN:CN CIV:CI CMR:CM COD:CD COG:CG COK:CK COL:CO COM:KM CPV:CV
  CRI:CR CUB:CU CUW:CW CXR:CX CYM:KY CYP:CY CZE:CZ DEU:DE DJI:DJ DMA:DM DNK:DK DOM:DO DZA:DZ
  ECU:EC EGY:EG ERI:ER ESH:EH ESP:ES EST:EE ETH:ET FIN:FI FJI:FJ FLK:FK FRA:FR FRO:FO FSM:FM
  GAB:GA GBR:GB GEO:GE GGY:GG GHA:GH GIB:GI GIN:GN GLP:GP GMB:GM GNB:GW GNQ:GQ GRC:GR GRD:GD
  GRL:GL GTM:GT GUF:GF GUM:GU GUY:GY HKG:HK HMD:HM HND:HN HRV:HR HTI:HT HUN:HU IDN:ID IMN:IM
  IND:IN IOT:IO IRL:IE IRN:IR IRQ:IQ ISL:IS ISR:IL ITA:IT JAM:JM JEY:JE JOR:JO JPN:JP KAZ:KZ
  KEN:KE KGZ:KG KHM:KH KIR:KI KNA:KN KOR:KR KWT:KW LAO:LA LBN:LB LBR:LR LBY:LY LCA:LC LIE:LI
  LKA:LK LSO:LS LTU:LT LUX:LU LVA:LV MAC:MO MAF:MF MAR:MA MCO:MC MDA:MD MDG:MG MDV:MV MEX:MX
  MHL:MH MKD:MK MLI:ML MLT:MT MMR:MM MNE:ME MNG:MN MNP:MP MOZ:MZ MRT:MR MSR:MS MTQ:MQ MUS:MU
  MWI:MW MYS:MY MYT:YT NAM:NA NCL:NC NER:NE NFK:NF NGA:NG NIC:NI NIU:NU NLD:NL NOR:NO NPL:NP
  NRU:NR NZL:NZ OMN:OM PAK:PK PAN:PA PCN:PN PER:PE PHL:PH PLW:PW PNG:PG POL:PL PRI:PR PRK:KP
  PRT:PT PRY:PY PSE:PS PYF:PF QAT:QA REU:RE ROU:RO RUS:RU RWA:RW SAU:SA SDN:SD SEN:SN SGP:SG
  SGS:GS SHN:SH SJM:SJ SLB:SB SLE:SL SLV:SV SMR:SM SOM:SO SPM:PM SRB:RS SSD:SS STP:ST SUR:SR
  SVK:SK SVN:SI SWE:SE SWZ:SZ SXM:SX SYC:SC SYR:SY TCA:TC TCD:TD TGO:TG THA:TH TJK:TJ TKL:TK
  TKM:TM TLS:TL TON:TO TTO:TT TUN:TN TUR:TR TUV:TV TWN:TW TZA:TZ UGA:UG UKR:UA UMI:UM URY:UY
  USA:US UZB:UZ VAT:VA VCT:VC VEN:VE VGB:VG VIR:VI VNM:VN VUT:VU WLF:WF WSM:WS YEM:YE ZAF:ZA
  ZMB:ZM ZWE:ZW XKS:XK
CODES

def token
  @token = nil if @token&.expired?
  @token ||= Spaceship::ConnectAPI::Token.create(
    key_id: ENV.fetch("ASC_KEY_ID"), issuer_id: ENV.fetch("ASC_ISSUER_ID"),
    key: ENV.fetch("ASC_KEY_CONTENT"), is_key_content_base64: true
  )
end

def fetch(url, auth: false)
  uri = URI(url)
  request = Net::HTTP::Get.new(uri)
  request["Authorization"] = "Bearer #{token.text}" if auth
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) { |http| http.request(request) }
  body = begin
    JSON.parse(response.body)
  rescue JSON::ParserError
    response.body
  end
  [response.code.to_i, body]
rescue StandardError => e
  [0, e.message]
end

# A GET on the App Store Connect API, following pages; returns [status, data, included].
def asc(path)
  url = path.start_with?("http") ? path : ASC + path
  data = []
  included = []
  status = nil
  while url
    status, body = fetch(url, auth: true)
    return [status, body, []] unless status == 200 && body.is_a?(Hash)
    page = body["data"]
    page.is_a?(Array) ? data.concat(page) : data << page
    included.concat(body["included"] || [])
    url = body.dig("links", "next")
  end
  [status, data, included]
end

def errors(body)
  return body.to_s[0, 300] unless body.is_a?(Hash)
  (body["errors"] || []).map { |e| "#{e['status']} #{e['code']}: #{e['detail'] || e['title']}" }.join("; ")
end

def heading(text)
  puts
  puts "== #{text}"
end

bundle_id = ENV.fetch("WAYSTAGE_BUNDLE_ID")
heading "App record (App Store Connect)"
status, apps, = asc("/v1/apps?filter[bundleId]=#{URI.encode_www_form_component(bundle_id)}")
abort "Could not read the app (HTTP #{status}): #{errors(apps)}" unless status == 200
abort "No app in App Store Connect with bundle ID #{bundle_id}" if apps.empty?
app = apps.first
app_id = app["id"]
attributes = app["attributes"] || {}
puts "Name:        #{attributes['name']}"
puts "Apple ID:    #{app_id}"
puts "Bundle ID:   #{attributes['bundleId']}"
puts "Primary language: #{attributes['primaryLocale']}"
%w[contentRightsDeclaration isOrEverWasMadeForKids].each do |key|
  puts "#{key}: #{attributes[key].inspect}" if attributes.key?(key)
end

heading "App Store versions (iOS)"
status, versions, = asc("/v1/apps/#{app_id}/appStoreVersions?filter[platform]=IOS&limit=20")
if status == 200
  versions.each do |version|
    v = version["attributes"]
    puts format("%-8s store state: %-24s version state: %-22s release: %-10s earliest: %s created: %s",
                v["versionString"], v["appStoreState"], v["appVersionState"].to_s, v["releaseType"].to_s,
                v["earliestReleaseDate"].to_s, v["createdDate"].to_s)
  end
  puts "(no versions)" if versions.empty?
else
  puts "Could not read versions (HTTP #{status}): #{errors(versions)}"
end

heading "App info (age rating and state)"
status, infos, = asc("/v1/apps/#{app_id}/appInfos")
if status == 200
  infos.each do |info|
    a = info["attributes"]
    puts "state: #{a['appStoreState'] || a['state']}  age rating: #{a['appStoreAgeRating']}  kids band: #{a['kidsAgeBand'].inspect}"
  end
else
  puts "Could not read app info (HTTP #{status}): #{errors(infos)}"
end

heading "Availability by country (App Store Connect)"
available = []
status, availability, = asc("/v2/appAvailabilities/#{app_id}")
if status == 200
  puts "Available in new countries automatically: #{availability.first.dig('attributes', 'availableInNewTerritories').inspect}"
  status, territories, = asc("/v2/appAvailabilities/#{app_id}/territoryAvailabilities?include=territory&limit=200")
  if status == 200
    unavailable = []
    territories.each do |entry|
      a = entry["attributes"] || {}
      code = entry.dig("relationships", "territory", "data", "id") || entry["id"]
      if a["available"]
        available << code
      else
        unavailable << code
      end
      statuses = Array(a["contentStatuses"])
      next if statuses == ["AVAILABLE"] || statuses.empty? && a["available"]
      puts "  #{code}: available=#{a['available'].inspect} release date=#{a['releaseDate'].inspect} statuses=#{statuses.join(',')}"
    end
    puts "Countries set up: #{territories.size}; marked available: #{available.size}; not available: #{unavailable.size}"
    puts "Available: #{available.sort.join(' ')}" unless available.empty?
    puts "United States (USA) available: #{available.include?('USA')}"
  else
    puts "Could not read the countries (HTTP #{status}): #{errors(territories)}"
  end
else
  puts "No availability record (HTTP #{status}): #{errors(availability)}"
  puts "  -> In App Store Connect, Pricing and Availability: the app has no countries set."
end

heading "Price (App Store Connect)"
status, schedule, included = asc("/v1/apps/#{app_id}/appPriceSchedule?include=baseTerritory,manualPrices")
if status == 200
  base = included.find { |i| i["type"] == "territories" }
  puts "Base country: #{base ? base['id'] : 'none'}"
  status, prices, points = asc("/v1/appPriceSchedules/#{app_id}/manualPrices?include=appPricePoint,territory&limit=50")
  if status == 200
    prices.each do |price|
      point_id = price.dig("relationships", "appPricePoint", "data", "id")
      point = points.find { |p| p["type"] == "appPricePoints" && p["id"] == point_id }
      territory = price.dig("relationships", "territory", "data", "id")
      a = price["attributes"] || {}
      puts "  #{territory}: customer price #{point&.dig('attributes', 'customerPrice').inspect} from #{a['startDate'].inspect} to #{a['endDate'].inspect}"
    end
    puts "  (no manual prices: the app has no price set)" if prices.empty?
  else
    puts "Could not read prices (HTTP #{status}): #{errors(prices)}"
  end
else
  puts "No price schedule (HTTP #{status}): #{errors(schedule)}"
  puts "  -> In App Store Connect, Pricing and Availability: no price is set."
end

heading "Public App Store: Apple's lookup service, every country"
codes = (available.empty? ? %w[USA] : available).map { |code| [code, ALPHA2[code]] }
found = []
missing = []
codes.each do |alpha3, alpha2|
  next missing << "#{alpha3}(no code)" unless alpha2
  status, body = fetch("https://itunes.apple.com/lookup?id=#{app_id}&country=#{alpha2.downcase}")
  if status == 200 && body.is_a?(Hash) && body["resultCount"].to_i.positive?
    found << alpha2
    if alpha2 == "US" || found.size == 1
      r = body["results"].first
      puts "  #{alpha2}: #{r['trackName']} #{r['version']} released #{r['releaseDate']} (current version #{r['currentVersionReleaseDate']}), price #{r['formattedPrice']}, min iOS #{r['minimumOsVersion']}"
    end
  else
    missing << alpha2
  end
  sleep 0.2
end
puts "Found in #{found.size} of #{codes.size} countries checked."
puts "Not found in: #{missing.join(' ')}" unless missing.empty?
status, body = fetch("https://itunes.apple.com/lookup?bundleId=#{URI.encode_www_form_component(bundle_id)}&country=us")
puts "Lookup by bundle ID in the US: #{body.is_a?(Hash) ? body['resultCount'] : "HTTP #{status}"} result(s)"

heading "Public App Store: product page"
uri = URI("https://apps.apple.com/us/app/id#{app_id}")
response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) { |http| http.get(uri.request_uri) }
puts "#{uri}: HTTP #{response.code}#{response['location'] ? " -> #{response['location']}" : ''}"
