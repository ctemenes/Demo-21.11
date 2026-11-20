%dw 2.0
output application/java
import try from dw::Runtime

// One row of the asset register CSV -> the works system's asset record.
// The source file is exported by hand from an older system, so the job
// tidies casing, spacing and dates here and rejects rows it cannot trust.
var assetTypes = {
    "RD": "ROAD_SEGMENT", "SL": "STREET_LIGHT", "BN": "BIN_SERVICE",
    "PK": "PARK_ASSET",   "DR": "DRAINAGE",     "SG": "SIGN"
}
fun clean(text) = if (text == null) null else trim(text replace /\s+/ with " ")
// Dates arrive as 2019-03-05 or 5/3/2019. Impossible dates (31/02/2019) are
// rejected instead of being quietly moved to the end of the month.
fun toDate(text) =
    if (isBlank(text)) null
    else if (text matches /^\d{4}-\d{2}-\d{2}$/)
        (if (try(() -> text as Date).success) text else null)
    else if (text matches /^\d{1,2}\/\d{1,2}\/\d{4}$/) do {
        var parsed = try(() -> text as Date {format: "d/M/yyyy"})
        var day = (text splitBy "/")[0] as Number
        ---
        if (parsed.success and parsed.result.day == day) (parsed.result as String {format: "yyyy-MM-dd"}) else null
    }
    else null
fun toNumber(text) = if (isBlank(text)) null else try(() -> trim(text) as Number).result
var id = upper(clean(payload.asset_id default ""))
var lat = toNumber(payload.latitude)
var lon = toNumber(payload.longitude)
var problems = [
    ("asset_id is missing or not like RD-000123") if (!(id matches /^[A-Z]{2}-\d{6}$/)),
    ("unknown asset type prefix") if ((id matches /^[A-Z]{2}-\d{6}$/) and assetTypes[id[0 to 1]] == null),
    ("suburb is missing") if (isBlank(payload.suburb)),
    ("postcode is not a Queensland postcode") if (!((payload.postcode default "") matches /^4\d{3}$/)),
    ("latitude or longitude is not a number") if ((!isBlank(payload.latitude) and lat == null) or (!isBlank(payload.longitude) and lon == null)),
    ("latitude or longitude is outside Queensland") if (lat != null and lon != null and (lat < -29.5 or lat > -9 or lon < 137.9 or lon > 153.6)),
    ("installed_on is not a date") if (!isBlank(payload.installed_on) and toDate(payload.installed_on) == null)
]
---
{
    valid: isEmpty(problems),
    problems: problems,
    record: {
        assetId: id,
        assetType: assetTypes[id[0 to 1]] default "UNKNOWN",
        description: clean(payload.description),
        suburb: upper(clean(payload.suburb default "")),
        postcode: payload.postcode,
        latitude: lat,
        longitude: lon,
        status: upper(clean(payload.status default "ACTIVE")),
        installedOn: toDate(payload.installed_on)
    }
}
