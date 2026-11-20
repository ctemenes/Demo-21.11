"""Build a realistic, deliberately messy asset register export.

The file imitates a hand-run export from an older system: mixed casing, stray
spaces, two date formats, and a known number of rows that must be rejected.
Seeded, so every run produces the same file and the expected counts hold.
"""
import csv
import random

SUBURBS = [("Paddington", "4064"), ("New Farm", "4005"), ("West End", "4101"), ("Toowong", "4066"),
           ("Chermside", "4032"), ("Indooroopilly", "4068"), ("Wynnum", "4178"), ("Sunnybank", "4109"),
           ("Carindale", "4152"), ("Nundah", "4012"), ("Kenmore", "4069"), ("Annerley", "4103")]
TYPES = {"RD": "Road segment", "SL": "Street light", "BN": "Bin service point",
         "PK": "Park asset", "DR": "Stormwater drain", "SG": "Street sign"}
GOOD_ROWS, BAD_ROWS = 238, 12


def good_row(rng, number):
    prefix = rng.choice(list(TYPES))
    suburb, postcode = rng.choice(SUBURBS)
    year, month, day = rng.randint(1998, 2025), rng.randint(1, 12), rng.randint(1, 28)
    installed = rng.choice([f"{year}-{month:02d}-{day:02d}", f"{day}/{month}/{year}", ""])
    style = rng.choice([str.upper, str.lower, str.title, lambda text: f"  {text} "])
    return {
        "asset_id": rng.choice([str.upper, str.lower])(f"{prefix}-{number:06d}"),
        "description": f"{TYPES[prefix]}   {rng.randint(1, 180)} {rng.choice(['North', 'South', 'East', 'West'])} side",
        "suburb": style(suburb),
        "postcode": postcode,
        "latitude": f"{-27.47 + rng.uniform(-0.12, 0.12):.6f}",
        "longitude": f"{153.02 + rng.uniform(-0.12, 0.12):.6f}",
        "status": rng.choice(["Active", "ACTIVE", "active", "Under repair", "Decommissioned"]),
        "installed_on": installed,
    }


def main():
    rng = random.Random(4064)
    rows = [good_row(rng, 1000 + index) for index in range(GOOD_ROWS)]
    breakers = [
        lambda r: r.update(asset_id="RD4512"),              # malformed id
        lambda r: r.update(asset_id=""),                    # missing id
        lambda r: r.update(asset_id="ZZ-" + r["asset_id"][3:]),  # unknown type
        lambda r: r.update(suburb=""),                      # missing suburb
        lambda r: r.update(postcode="2000"),                # not Queensland
        lambda r: r.update(postcode="40X4"),                # not a postcode
        lambda r: r.update(latitude="north-ish"),           # not a number
        lambda r: r.update(latitude="-33.868800", longitude="151.209300"),  # Sydney
        lambda r: r.update(installed_on="31/02/2019"),      # impossible date
        lambda r: r.update(installed_on="last winter"),     # not a date
        lambda r: r.update(asset_id="SL-12"),               # too short
        lambda r: r.update(postcode=""),                    # missing postcode
    ]
    assert len(breakers) == BAD_ROWS
    for index, breaker in enumerate(breakers):
        row = good_row(rng, 9000 + index)
        breaker(row)
        rows.insert(rng.randint(0, len(rows)), row)
    with open("data/asset-register.csv", "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    print(f"wrote {len(rows)} rows: {GOOD_ROWS} good, {BAD_ROWS} that must be rejected")


if __name__ == "__main__":
    main()
