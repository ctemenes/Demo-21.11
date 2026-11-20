%dw 2.0
// Routing rules: which department owns each category, how urgent it is and
// how long the department has to resolve it. One place to change the rules.
var rules = {
    pothole:         { department: "Roads and Drainage",     priority: "HIGH",   slaHours: 48 },
    fallen_tree:     { department: "Parks and Open Space",   priority: "HIGH",   slaHours: 24 },
    street_light:    { department: "Roads and Drainage",     priority: "MEDIUM", slaHours: 120 },
    missed_bin:      { department: "Waste and Resource Recovery", priority: "MEDIUM", slaHours: 48 },
    illegal_dumping: { department: "Waste and Resource Recovery", priority: "MEDIUM", slaHours: 72 },
    graffiti:        { department: "City Cleansing",          priority: "LOW",    slaHours: 240 },
    other:           { department: "Customer Service",        priority: "LOW",    slaHours: 240 }
}

fun routeFor(category: String) = rules[category] default rules.other
