%dw 2.0
output application/json
import * from modules::routing

// Public request -> canonical message for the works management queue.
// vars.trackingId and vars.receivedAt are set once in the flow so the receipt
// and the queued message always agree.
var route = routeFor(payload.category)
fun clean(text) = if (text == null) null else trim(text replace /\s+/ with " ")
---
{
    schemaVersion: "1.0",
    trackingId: vars.trackingId,
    correlationId: correlationId,
    receivedAt: vars.receivedAt,
    source: {
        system: "service-request-api",
        channel: payload.channel default "web"
    },
    request: {
        category: payload.category,
        priority: route.priority,
        description: clean(payload.description)
    },
    routing: {
        department: route.department,
        slaHours: route.slaHours
    },
    location: {
        address: clean(payload.location.address),
        suburb: upper(clean(payload.location.suburb)),
        postcode: payload.location.postcode,
        (latitude: payload.location.latitude) if (payload.location.latitude?),
        (longitude: payload.location.longitude) if (payload.location.longitude?)
    },
    (assetId: payload.assetId) if (payload.assetId?),
    reporter: {
        name: clean(payload.reporter.name),
        email: lower(trim(payload.reporter.email)),
        (phone: payload.reporter.phone replace /[^0-9+]/ with "") if (payload.reporter.phone?)
    }
}
