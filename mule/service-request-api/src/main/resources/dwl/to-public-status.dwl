%dw 2.0
output application/json
// Works management system record (snake_case, UTC) -> public status
// (camelCase, Brisbane time). Reporter details never leave the back office.
fun brisbane(utcText) = if (utcText == null) null
    else ((utcText as DateTime) >> "Australia/Brisbane") as String {format: "yyyy-MM-dd'T'HH:mm:ssXXX"}
---
{
    trackingId: payload.tracking_id,
    status: payload.status_code,
    category: payload.category_code,
    department: payload.department_name,
    priority: payload.priority_code,
    suburb: payload.suburb_name,
    receivedAt: brisbane(payload.received_utc),
    targetResolutionAt: brisbane(payload.sla_due_utc)
}
