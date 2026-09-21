#!/usr/bin/env python3
"""
simulate_claims.py
===================
Simulates a live claims-processing system: new members enroll, new
providers join the network, and new claims arrive continuously, all
inserted into the denormalized claims_source.claim_events table in
PostgreSQL (see 03_claims_denormalized_source.sql).

This script is entirely self-contained. It knows nothing about
WarehousePG, or about any pre-existing groups/members/providers/claims
that might already be loaded there -- it generates its own new business
from scratch, the way a real operational claims system would, and simply
writes ordinary, small, per-claim transactions into Postgres. Everything
downstream of that (PGAA replicating this table to Iceberg on S3, a
WarehousePG external table reading it, and a separate step folding new
rows into the normalized claims_demo tables) is somebody else's problem.

To avoid ever colliding with IDs a warehouse might have loaded from
elsewhere, new claim/member/provider/group ids here are numbered well
above typical seed-data sizes (see the *_ID_BASE constants below).

Setup
-----
    python3 -m ensurepip --upgrade --user
    python3 -m pip install --user psycopg2-binary

Usage
-----
    # No flags at all: connects the same way `psql` does, using whatever
    # PGDATABASE/PGHOST/PGUSER/etc. (or peer auth) is already set up in
    # this shell. Runs until Ctrl+C at ~12 claims/minute.
    python3 simulate_claims.py

    # Point at a specific database instead of relying on env vars.
    python3 simulate_claims.py --dsn postgresql://user:pass@host:5432/claimsource

    # Fixed batch instead of an open-ended stream, faster pace.
    python3 simulate_claims.py --count 200 --rate 60

    # See what it would generate without touching the database.
    python3 simulate_claims.py --dry-run --count 3

--dsn is only needed if the default (libpq env vars / peer auth, same as
a bare `psql`) doesn't already point where you want. It can also be set
via the CLAIMS_DSN environment variable instead of passing a flag.
"""

import argparse
import datetime as dt
import os
import random
import signal
import sys
import time
from decimal import Decimal, ROUND_HALF_UP

import psycopg2
import psycopg2.extras


# ---------------------------------------------------------------------------
# Id ranges. Chosen to stay clear of the current seed data sizes (02_medical
# _claims_seed_data.sql loads 10 groups, 200,000 members, 5,000 providers,
# and 1,500,000 claims) without this script ever having to query or know
# anything about that data.
#
# The bases below sat right in the middle of the seed ranges after the seed
# script was scaled up (member/claim counts grew from 200/1,500 to
# 200,000/1,500,000, but these bases weren't raised to match). New "members"
# generated starting at 100001 landed on IDs 100001-200000 that seed data
# already used, so every one of them got silently skipped by the
# `member_id NOT IN (SELECT member_id FROM claims_demo.members)` guard in
# stage.fn_load_incremental -- the member table wasn't failing to grow, it
# was never getting genuinely new IDs to add. New claims would hit the same
# problem as a hard PK violation once claim_id reached the 1,000,001-
# 1,500,000 overlap. Bumped well clear of the current seed sizes, with
# plenty of headroom for the seed script to grow further later.
# ---------------------------------------------------------------------------

GROUP_ID_BASE = 1_000_001
MEMBER_ID_BASE = 5_000_001
PROVIDER_ID_BASE = 2_000_001
CLAIM_ID_BASE = 10_000_001

# Diagnosis (ICD-10-CM) and procedure (CPT/HCPCS) codes are real,
# standardized medical vocabularies, not warehouse-specific data, so it's
# fine -- and realistic -- to reuse the same fixed code lists every time.
DIAGNOSES = [
    (1,  'E11.9',    'Type 2 diabetes mellitus without complications',                  'Endocrine',                   True),
    (2,  'I10',      'Essential (primary) hypertension',                               'Circulatory',                 True),
    (3,  'J06.9',    'Acute upper respiratory infection, unspecified',                 'Respiratory',                 False),
    (4,  'M54.5',    'Low back pain',                                                  'Musculoskeletal',             False),
    (5,  'K21.9',    'Gastro-esophageal reflux disease without esophagitis',           'Digestive',                   True),
    (6,  'F41.9',    'Anxiety disorder, unspecified',                                  'Mental Health',               True),
    (7,  'N39.0',    'Urinary tract infection, site not specified',                    'Genitourinary',               False),
    (8,  'J45.909',  'Unspecified asthma, uncomplicated',                              'Respiratory',                 True),
    (9,  'E78.5',    'Hyperlipidemia, unspecified',                                    'Endocrine',                   True),
    (10, 'M25.50',   'Pain in unspecified joint',                                      'Musculoskeletal',             False),
    (11, 'R51',      'Headache',                                                       'Nervous System',              False),
    (12, 'Z00.00',   'Encounter for general adult medical exam w/o abnormal findings', 'Factors Influencing Health',  False),
    (13, 'O80',      'Encounter for full-term uncomplicated delivery',                 'Pregnancy/Childbirth',        False),
    (14, 'S52.501A', 'Fracture of lower end of radius, unspecified, initial encounter','Injury',                      False),
    (15, 'C50.911',  'Malignant neoplasm of unspecified site of right female breast',  'Neoplasms',                   True),
]

PROCEDURES = [
    (1,  '99213', 'Office/outpatient visit, established patient, low complexity',      'Evaluation & Management', 'CPT',   False),
    (2,  '99214', 'Office/outpatient visit, established patient, moderate complexity', 'Evaluation & Management', 'CPT',   False),
    (3,  '99203', 'Office/outpatient visit, new patient, low complexity',              'Evaluation & Management', 'CPT',   False),
    (4,  '80053', 'Comprehensive metabolic panel',                                     'Laboratory',              'CPT',   False),
    (5,  '85025', 'Complete blood count (CBC) with differential',                      'Laboratory',              'CPT',   False),
    (6,  '93000', 'Electrocardiogram, routine ECG with interpretation',                'Diagnostic',              'CPT',   False),
    (7,  '71046', 'Chest X-ray, 2 views',                                              'Radiology',               'CPT',   False),
    (8,  '73721', 'MRI, lower extremity joint',                                        'Radiology',               'CPT',   False),
    (9,  '29881', 'Knee arthroscopy with meniscectomy',                                'Surgery',                 'CPT',   False),
    (10, '45378', 'Colonoscopy, diagnostic',                                           'Surgery',                 'CPT',   False),
    (11, '90834', 'Psychotherapy, 45 minutes',                                         'Behavioral Health',       'CPT',   False),
    (12, 'J1100', 'Injection, dexamethasone sodium phosphate, 1 mg',                   'Drug/Injection',          'HCPCS', False),
    (13, 'G0439', 'Annual wellness visit, includes personalized prevention plan',      'Preventive',              'HCPCS', True),
    (14, '99284', 'Emergency department visit, moderate severity',                     'Evaluation & Management', 'CPT',   False),
    (15, '27447', 'Total knee arthroplasty',                                           'Surgery',                 'CPT',   False),
    (16, '90471', 'Immunization administration (one vaccine)',                         'Preventive',              'CPT',   True),
]

# Procedure ids used for dedicated preventative visits (checkup / vaccine),
# and the diagnosis used alongside them (Z00.00, general wellness exam).
PREVENTATIVE_PROCEDURE_IDS = [p[0] for p in PROCEDURES if p[5]]
PREVENTATIVE_DIAGNOSIS_ID = 12

FIRST_NAMES = ['James', 'Mary', 'John', 'Patricia', 'Robert', 'Jennifer', 'Michael', 'Linda', 'William', 'Elizabeth',
               'David', 'Barbara', 'Richard', 'Susan', 'Joseph', 'Jessica', 'Carlos', 'Maria', 'Wei', 'Priya',
               'Ahmed', 'Sofia', 'Noah', 'Olivia', 'Liam', 'Emma', 'Yuki', 'Fatima', 'Diego', 'Grace']
LAST_NAMES = ['Smith', 'Johnson', 'Williams', 'Brown', 'Jones', 'Garcia', 'Miller', 'Davis', 'Rodriguez', 'Martinez',
              'Wilson', 'Anderson', 'Taylor', 'Thomas', 'Moore', 'Jackson', 'Lee', 'Patel', 'Nguyen', 'Kim',
              'Hassan', 'Ivanov', 'Silva', 'Chen', 'Okafor']
CITY_STATE = [('Columbus', 'OH'), ('Austin', 'TX'), ('Seattle', 'WA'), ('Atlanta', 'GA'), ('Portland', 'OR'),
              ('Albany', 'NY'), ('Manchester', 'NH'), ('Boston', 'MA'), ('Denver', 'CO'), ('Miami', 'FL'),
              ('Phoenix', 'AZ'), ('Raleigh', 'NC'), ('Minneapolis', 'MN'), ('Nashville', 'TN'), ('St. Louis', 'MO')]
SPECIALTIES = [
    ('207Q00000X', 'Family Medicine'), ('207R00000X', 'Internal Medicine'),
    ('207RC0000X', 'Cardiovascular Disease'), ('208D00000X', 'General Practice'),
    ('2084P0800X', 'Psychiatry'), ('363L00000X', 'Nurse Practitioner'),
    ('207X00000X', 'Orthopaedic Surgery'), ('261QP2300X', 'Physical Therapy Clinic'),
    ('282N00000X', 'General Acute Care Hospital'), ('367500000X', 'Radiology'),
    ('208000000X', 'Pediatrics'), ('363LF0000X', 'Nurse Practitioner, Family'),
]
GROUP_NAME_PREFIXES = ['Summit', 'Cedar Ridge', 'Northgate', 'Bright Path', 'Union Square', 'Meridian',
                        'Pinecrest', 'Redwood', 'Silver Creek', 'Vantage', 'Lakeshore', 'Copper Hill',
                        'Stonebridge', 'Amber Valley', 'Harborview']
GROUP_NAME_SUFFIXES = ['Manufacturing', 'Logistics', 'Health Systems', 'Retail Group', 'School District',
                        'Financial Partners', 'University', 'Insurance Associates', 'Construction Co.',
                        'Technologies', 'Holdings', 'Enterprises']
GROUP_TYPES = ['Employer', 'Employer', 'Employer', 'Government', 'Association']
FUNDING_TYPES = ['Fully Insured', 'Fully Insured', 'Self Funded']

CLAIM_TYPES = ['Professional', 'Professional', 'Professional', 'Institutional', 'Dental']
PLACES_OF_SERVICE = ['11', '21', '22', '23', '19']
MODIFIERS = ['25', '59', 'LT', 'RT']

TWO_PLACES = Decimal('0.01')


def money(x):
    """Round to 2 decimal places as a Decimal, regardless of input type."""
    if not isinstance(x, Decimal):
        x = Decimal(str(x))
    return x.quantize(TWO_PLACES, rounding=ROUND_HALF_UP)


# ---------------------------------------------------------------------------
# Connecting without a DSN: psycopg2-binary bundles its own libpq, which
# defaults to /var/run/postgresql for its Unix socket regardless of where
# the local PostgreSQL install actually puts one (RHEL/EDB commonly uses
# /var/run/edb-pge or /tmp instead). connect_auto() tries the environment's
# own defaults first, then a handful of known socket directories, so the
# script works out of the box without needing PGHOST set -- same as `psql`
# already does by picking up the system libpq's compiled-in default.
# ---------------------------------------------------------------------------

_SOCKET_DIR_CANDIDATES = ['/var/run/postgresql', '/var/run/edb-pge', '/tmp', '/run/postgresql']
_resolved_host = {'value': 'unset', 'announced': False}


def connect_auto(dsn):
    if dsn:
        return psycopg2.connect(dsn)

    if _resolved_host['value'] != 'unset':
        host = _resolved_host['value']
        return psycopg2.connect(host=host) if host else psycopg2.connect()

    try:
        conn = psycopg2.connect()
        _resolved_host['value'] = None
        return conn
    except psycopg2.OperationalError as first_error:
        for candidate in _SOCKET_DIR_CANDIDATES:
            try:
                conn = psycopg2.connect(host=candidate)
                _resolved_host['value'] = candidate
                if not _resolved_host['announced']:
                    print(f"  [info] connected via Unix socket in {candidate} "
                          f"(auto-detected; set PGHOST or --dsn to skip this probe next time)")
                    _resolved_host['announced'] = True
                return conn
            except psycopg2.OperationalError:
                continue
        raise first_error


# ---------------------------------------------------------------------------
# The simulated world: a self-contained, growing pool of groups, members
# and providers. It starts with a small seed population and organically
# adds new members (enrollments), new providers (network additions), and
# occasionally new groups (new employer sold) as the simulation runs --
# no database read required to build any of this.
# ---------------------------------------------------------------------------

class ClaimsWorld:
    def __init__(self, seed_groups=5, seed_members=25, seed_providers=12):
        self._next_group_id = GROUP_ID_BASE
        self._next_member_id = MEMBER_ID_BASE
        self._next_provider_id = PROVIDER_ID_BASE

        self.groups = {}
        self.members = []
        self.providers = []
        self.diagnosis = [
            {'diagnosis_id': d[0], 'diagnosis_code': d[1], 'diagnosis_desc': d[2],
             'diagnosis_category': d[3], 'chronic_flag': d[4]}
            for d in DIAGNOSES
        ]
        self.procedures = [
            {'procedure_id': p[0], 'procedure_code': p[1], 'procedure_desc': p[2],
             'procedure_category': p[3], 'code_type': p[4], 'is_preventative': p[5]}
            for p in PROCEDURES
        ]
        self.preventative_procedures = [p for p in self.procedures if p['is_preventative']]

        for _ in range(seed_groups):
            self.add_group()
        for _ in range(seed_members):
            self.add_member()
        for _ in range(seed_providers):
            self.add_provider()

    def add_group(self):
        group_id = self._next_group_id
        self._next_group_id += 1
        city, state = random.choice(CITY_STATE)
        name = f"{random.choice(GROUP_NAME_PREFIXES)} {random.choice(GROUP_NAME_SUFFIXES)}"
        group = {
            'group_id': group_id,
            'group_name': name,
            'group_type': random.choice(GROUP_TYPES),
            'funding_type': random.choice(FUNDING_TYPES),
            'industry_sic': f"{random.randint(1000, 8999)}",
            'state': state,
            'effective_date': None,
            'termination_date': None,
        }
        self.groups[group_id] = group
        return group

    def add_member(self):
        group = random.choice(list(self.groups.values()))
        member_id = self._next_member_id
        self._next_member_id += 1
        city, state = random.choice(CITY_STATE)
        member = {
            'member_id': member_id,
            'group_id': group['group_id'],
            'subscriber_id': f"SUB{member_id:08d}",
            'first_name': random.choice(FIRST_NAMES),
            'last_name': random.choice(LAST_NAMES),
            'date_of_birth': None,
            'gender': random.choice(['M', 'F']),
            'relationship_code': random.choice(['Subscriber', 'Spouse', 'Dependent', 'Dependent']),
            'plan_type': random.choice(['HMO', 'PPO', 'EPO', 'HDHP']),
            'address_line1': None,
            'city': city,
            'state': state,
            'zip_code': None,
            'effective_date': dt.date.today(),
            'termination_date': None,
        }
        self.members.append(member)
        return member

    def add_provider(self):
        provider_id = self._next_provider_id
        self._next_provider_id += 1
        taxonomy_code, specialty_desc = random.choice(SPECIALTIES)
        city, state = random.choice(CITY_STATE)
        provider = {
            'provider_id': provider_id,
            'npi': f"{1_900_000_000 + provider_id:010d}",
            'provider_name': f"{specialty_desc} Associates of {city}",
            'provider_type': random.choice(['Individual', 'Individual', 'Facility', 'Group']),
            'taxonomy_code': taxonomy_code,
            'specialty_desc': specialty_desc,
            'state': state,
            'network_status': 'In-Network' if random.random() < 0.85 else 'Out-of-Network',
        }
        self.providers.append(provider)
        return provider

    def maybe_grow(self, member_rate=0.05, provider_rate=0.02, group_rate=0.005):
        """Occasionally onboard new business before the next claim is
        generated. Returns a list of (kind, entity) tuples for anything
        just added, so the caller can log it."""
        added = []
        if random.random() < group_rate:
            added.append(('group', self.add_group()))
        if random.random() < member_rate:
            added.append(('member', self.add_member()))
        if random.random() < provider_rate:
            added.append(('provider', self.add_provider()))
        return added


# ---------------------------------------------------------------------------
# Claim generation
# ---------------------------------------------------------------------------

def weighted_claim_status():
    r = random.random()
    if r < 0.80:
        return 'Paid'
    elif r < 0.92:
        return 'Denied'
    return 'Pending'


def generate_claim(world, claim_id, now=None):
    """Returns a list of 1-3 row dicts (one per claim_line) for one claim.

    ~20% of claims are generated as dedicated preventative visits (checkup
    and/or vaccine only), at lower cost and fully covered ($0 member
    responsibility when Paid). claim_is_preventative on the returned rows
    is always derived from the actual lines built (true iff every line's
    procedure is preventative), not from this branch directly, so it stays
    correct even if a "regular" claim's random draw happens to land
    entirely on a preventative code too.
    """
    now = now or dt.datetime.now()
    member = random.choice(world.members)
    group = world.groups.get(member['group_id'])
    billing_provider = random.choice(world.providers)

    claim_type = random.choice(CLAIM_TYPES)
    claim_status = weighted_claim_status()
    is_preventative_visit = random.random() < 0.20

    service_date_start = now.date() - dt.timedelta(days=random.randint(0, 10))
    service_date_end = service_date_start + dt.timedelta(days=random.randint(0, 2))
    received_date = now.date()
    paid_date = (service_date_start + dt.timedelta(days=random.randint(10, 25))
                 if claim_status == 'Paid' else None)

    if is_preventative_visit:
        line_count = random.randint(1, 2)
        wellness_diagnosis = next(d for d in world.diagnosis if d['diagnosis_id'] == PREVENTATIVE_DIAGNOSIS_ID)
    else:
        line_count = random.randint(1, 3)

    lines = []
    claim_billed = claim_allowed = claim_paid = claim_member_resp = Decimal('0.00')

    for line_number in range(1, line_count + 1):
        if is_preventative_visit:
            procedure = random.choice(world.preventative_procedures)
            diagnosis = wellness_diagnosis
        else:
            procedure = random.choice(world.procedures)
            diagnosis = random.choice(world.diagnosis)
        # usually the same provider renders and bills; occasionally different
        rendering_provider = billing_provider if random.random() < 0.85 else random.choice(world.providers)

        if is_preventative_visit:
            billed = money(random.uniform(30, 200))          # wellness visit / vaccine: lower cost
            allowed = billed                                  # fully allowed, no network discount
            paid = allowed if claim_status == 'Paid' else Decimal('0.00')   # $0 member cost-share when paid
        else:
            billed = money(random.uniform(50, 1000))
            allowed = money(billed * Decimal(str(random.uniform(0.55, 0.90))))
            if claim_status in ('Denied', 'Pending'):
                paid = Decimal('0.00')
            else:
                paid = money(allowed * Decimal(str(random.uniform(0.70, 1.00))))
        member_resp = max(allowed - paid, Decimal('0.00'))
        copay = money(member_resp * Decimal('0.3'))
        coinsurance = money(member_resp * Decimal('0.4'))
        deductible = money(member_resp - copay - coinsurance)  # exact reconciliation

        claim_billed += billed
        claim_allowed += allowed
        claim_paid += paid
        claim_member_resp += member_resp

        lines.append({
            'claim_id': claim_id,
            'line_number': line_number,
            'claim_type': claim_type,
            'claim_status': claim_status,
            'received_date': received_date,
            'service_date_start': service_date_start,
            'service_date_end': service_date_end,
            'paid_date': paid_date,
            'line_service_date': service_date_start,
            'place_of_service': random.choice(PLACES_OF_SERVICE),
            'modifier_code': random.choice(MODIFIERS) if random.random() < 0.15 else None,
            'units': random.randint(1, 3),
            'line_billed_amount': billed,
            'line_allowed_amount': allowed,
            'line_paid_amount': paid,
            'line_copay_amount': copay,
            'line_coinsurance_amount': coinsurance,
            'line_deductible_amount': deductible,
            'line_status': 'Denied' if claim_status == 'Denied' else 'Paid',

            'member_id': member['member_id'],
            'member_subscriber_id': member['subscriber_id'],
            'member_first_name': member['first_name'],
            'member_last_name': member['last_name'],
            'member_date_of_birth': member['date_of_birth'],
            'member_gender': member['gender'],
            'member_relationship_code': member['relationship_code'],
            'member_plan_type': member['plan_type'],
            'member_address_line1': member['address_line1'],
            'member_city': member['city'],
            'member_state': member['state'],
            'member_zip_code': member['zip_code'],
            'member_effective_date': member['effective_date'],
            'member_termination_date': member['termination_date'],

            'group_id': member['group_id'],
            'group_name': (group or {}).get('group_name'),
            'group_type': (group or {}).get('group_type'),
            'group_funding_type': (group or {}).get('funding_type'),
            'group_industry_sic': (group or {}).get('industry_sic'),
            'group_state': (group or {}).get('state'),
            'group_effective_date': (group or {}).get('effective_date'),
            'group_termination_date': (group or {}).get('termination_date'),

            'billing_provider_id': billing_provider['provider_id'],
            'billing_provider_npi': billing_provider['npi'],
            'billing_provider_name': billing_provider['provider_name'],
            'billing_provider_type': billing_provider['provider_type'],
            'billing_provider_taxonomy_code': billing_provider['taxonomy_code'],
            'billing_provider_specialty_desc': billing_provider['specialty_desc'],
            'billing_provider_state': billing_provider['state'],
            'billing_provider_network_status': billing_provider['network_status'],

            'rendering_provider_id': rendering_provider['provider_id'],
            'rendering_provider_npi': rendering_provider['npi'],
            'rendering_provider_name': rendering_provider['provider_name'],
            'rendering_provider_specialty_desc': rendering_provider['specialty_desc'],
            'rendering_provider_state': rendering_provider['state'],
            'rendering_provider_network_status': rendering_provider['network_status'],

            'diagnosis_id': diagnosis['diagnosis_id'],
            'diagnosis_code': diagnosis['diagnosis_code'],
            'diagnosis_desc': diagnosis['diagnosis_desc'],
            'diagnosis_category': diagnosis['diagnosis_category'],
            'diagnosis_chronic_flag': diagnosis['chronic_flag'],

            'procedure_id': procedure['procedure_id'],
            'procedure_code': procedure['procedure_code'],
            'procedure_desc': procedure['procedure_desc'],
            'procedure_category': procedure['procedure_category'],
            'procedure_code_type': procedure['code_type'],
            'procedure_is_preventative': procedure['is_preventative'],
        })

    claim_is_preventative = all(row['procedure_is_preventative'] for row in lines)
    for row in lines:
        row['claim_total_billed_amount'] = claim_billed
        row['claim_total_allowed_amount'] = claim_allowed
        row['claim_total_paid_amount'] = claim_paid
        row['claim_total_member_resp_amount'] = claim_member_resp
        row['claim_is_preventative'] = claim_is_preventative

    return lines


# ---------------------------------------------------------------------------
# Database I/O
# ---------------------------------------------------------------------------

INSERT_COLUMNS = [
    'claim_id', 'line_number', 'claim_type', 'claim_status', 'claim_is_preventative', 'received_date',
    'service_date_start', 'service_date_end', 'paid_date',
    'claim_total_billed_amount', 'claim_total_allowed_amount',
    'claim_total_paid_amount', 'claim_total_member_resp_amount',
    'line_service_date', 'place_of_service', 'modifier_code', 'units',
    'line_billed_amount', 'line_allowed_amount', 'line_paid_amount',
    'line_copay_amount', 'line_coinsurance_amount', 'line_deductible_amount', 'line_status',
    'member_id', 'member_subscriber_id', 'member_first_name', 'member_last_name',
    'member_date_of_birth', 'member_gender', 'member_relationship_code', 'member_plan_type',
    'member_address_line1', 'member_city', 'member_state', 'member_zip_code',
    'member_effective_date', 'member_termination_date',
    'group_id', 'group_name', 'group_type', 'group_funding_type', 'group_industry_sic',
    'group_state', 'group_effective_date', 'group_termination_date',
    'billing_provider_id', 'billing_provider_npi', 'billing_provider_name', 'billing_provider_type',
    'billing_provider_taxonomy_code', 'billing_provider_specialty_desc',
    'billing_provider_state', 'billing_provider_network_status',
    'rendering_provider_id', 'rendering_provider_npi', 'rendering_provider_name',
    'rendering_provider_specialty_desc', 'rendering_provider_state', 'rendering_provider_network_status',
    'diagnosis_id', 'diagnosis_code', 'diagnosis_desc', 'diagnosis_category', 'diagnosis_chronic_flag',
    'procedure_id', 'procedure_code', 'procedure_desc', 'procedure_category', 'procedure_code_type',
    'procedure_is_preventative',
]


def get_next_claim_id(conn, schema, table, override=None):
    if override is not None:
        return override
    with conn.cursor() as cur:
        cur.execute(f"SELECT COALESCE(MAX(claim_id), %s) + 1 FROM {schema}.{table}", (CLAIM_ID_BASE - 1,))
        return cur.fetchone()[0]


def insert_claim(conn, schema, table, lines):
    values = [[row.get(col) for col in INSERT_COLUMNS] for row in lines]
    cols_sql = ", ".join(INSERT_COLUMNS)
    sql = f"INSERT INTO {schema}.{table} ({cols_sql}) VALUES %s"
    with conn.cursor() as cur:
        psycopg2.extras.execute_values(cur, sql, values)
    conn.commit()


def connect_with_retry(dsn, max_wait=30):
    wait = 1
    while True:
        try:
            conn = connect_auto(dsn)
            conn.autocommit = False
            return conn
        except psycopg2.OperationalError as e:
            print(f"  [warn] connect failed ({e}); retrying in {wait}s...", file=sys.stderr)
            time.sleep(wait)
            wait = min(wait * 2, max_wait)


def mask_dsn(dsn):
    if not dsn:
        return "(libpq default / PG* env vars)"
    if '@' in dsn:
        head, tail = dsn.split('@', 1)
        if ':' in head:
            scheme_user = head.rsplit(':', 1)[0]
            return f"{scheme_user}:***@{tail}"
    return dsn


# ---------------------------------------------------------------------------
# Console output
# ---------------------------------------------------------------------------

def log_growth(added):
    ts = dt.datetime.now().strftime('%H:%M:%S')
    for kind, entity in added:
        if kind == 'member':
            print(f"[{ts}] NEW MEMBER   id={entity['member_id']:<8} "
                  f"{entity['first_name']} {entity['last_name']} ({entity['city']}, {entity['state']}) "
                  f"enrolled under group {entity['group_id']}")
        elif kind == 'provider':
            print(f"[{ts}] NEW PROVIDER id={entity['provider_id']:<8} {entity['provider_name']} "
                  f"({entity['specialty_desc']}) joined the network")
        elif kind == 'group':
            print(f"[{ts}] NEW GROUP    id={entity['group_id']:<8} {entity['group_name']} added")


def log_claim(lines, verbose=False):
    first = lines[0]
    ts = dt.datetime.now().strftime('%H:%M:%S')
    member = f"{first['member_first_name']} {first['member_last_name']}"
    provider = first['billing_provider_name'] or f"provider #{first['billing_provider_id']}"
    print(f"[{ts}] claim_id={first['claim_id']:<8} member={member:<20} "
          f"provider={provider:<40} lines={len(lines)}  "
          f"status={first['claim_status']:<8} billed=${first['claim_total_billed_amount']}")
    if verbose:
        for row in lines:
            print(f"           line {row['line_number']}: {row['procedure_code']} / {row['diagnosis_code']} "
                  f"-> billed=${row['line_billed_amount']} paid=${row['line_paid_amount']}")


def log_summary(stats, final=False):
    elapsed = time.time() - stats['start']
    rate = stats['claims'] / elapsed * 60 if elapsed > 0 else 0.0
    tag = "FINAL --" if final else "--"
    print(f"{tag} {stats['claims']} claims / {stats['lines']} lines inserted "
          f"in {elapsed:0.0f}s (~{rate:.1f} claims/min), ${stats['billed']} total billed --")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Simulate a live claims-processing system (new members, providers, and claims) "
                    "and insert the results into claims_source.claim_events.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument('--dsn', default=os.environ.get('CLAIMS_DSN'),
                         help="Target Postgres connection string. Falls back to $CLAIMS_DSN, "
                              "then libpq PG* env vars (same as a bare `psql`).")
    parser.add_argument('--schema', default='claims_source', help="Target schema (default: claims_source).")
    parser.add_argument('--table', default='claim_events', help="Target table (default: claim_events).")
    parser.add_argument('--rate', type=float, default=10000.0,
                         help="Average claims per minute (default: 10000).")
    parser.add_argument('--jitter', type=float, default=0.4,
                         help="Fraction (0-1) of the interval to randomize, for bursty-looking "
                              "arrivals instead of a metronome (default: 0.4).")
    parser.add_argument('--count', type=int, default=None,
                         help="Stop after N claims (default: run until Ctrl+C).")
    parser.add_argument('--start-claim-id', type=int, default=None,
                         help=f"First claim_id to use (default: auto-detect MAX(claim_id)+1 "
                              f"from the target table, or {CLAIM_ID_BASE} if it's empty).")
    parser.add_argument('--seed-members', type=int, default=25, help="Starting member pool size (default: 25).")
    parser.add_argument('--seed-providers', type=int, default=12, help="Starting provider pool size (default: 12).")
    parser.add_argument('--seed-groups', type=int, default=5, help="Starting group pool size (default: 5).")
    parser.add_argument('--new-member-rate', type=float, default=0.05,
                         help="Probability a new member enrolls before each claim (default: 0.05).")
    parser.add_argument('--new-provider-rate', type=float, default=0.02,
                         help="Probability a new provider joins before each claim (default: 0.02).")
    parser.add_argument('--new-group-rate', type=float, default=0.005,
                         help="Probability a new group is added before each claim (default: 0.005).")
    parser.add_argument('--seed', type=int, default=None, help="Random seed, for reproducible runs.")
    parser.add_argument('--dry-run', action='store_true',
                         help="Generate and print claims without connecting to the target database.")
    parser.add_argument('-v', '--verbose', action='store_true', help="Also print each line within a claim.")
    args = parser.parse_args()

    if args.seed is not None:
        random.seed(args.seed)

    print("=" * 72)
    print("Medical claims real-time simulator")
    print("=" * 72)
    print(f"  target    : {args.schema}.{args.table}  (dsn: {mask_dsn(args.dsn)})")
    print(f"  world     : self-contained ({args.seed_groups} groups / {args.seed_members} members / "
          f"{args.seed_providers} providers to start, growing over time)")
    print(f"  rate      : ~{args.rate:.1f} claims/min (jitter {args.jitter:.0%})")
    print(f"  count     : {'unlimited (Ctrl+C to stop)' if args.count is None else args.count}")
    print("=" * 72)

    world = ClaimsWorld(seed_groups=args.seed_groups, seed_members=args.seed_members,
                         seed_providers=args.seed_providers)
    print(f"Starting world: {len(world.groups)} groups, {len(world.members)} members, "
          f"{len(world.providers)} providers, {len(world.diagnosis)} diagnosis codes, "
          f"{len(world.procedures)} procedure codes.\n")

    conn = None
    if not args.dry_run:
        conn = connect_with_retry(args.dsn)

    if args.start_claim_id is not None:
        next_claim_id = args.start_claim_id
    elif args.dry_run:
        next_claim_id = CLAIM_ID_BASE
    else:
        next_claim_id = get_next_claim_id(conn, args.schema, args.table)
    print(f"Starting at claim_id={next_claim_id}\n")

    stats = {'claims': 0, 'lines': 0, 'billed': Decimal('0.00'), 'start': time.time()}

    stop = {'flag': False}

    def handle_stop(signum, frame):
        stop['flag'] = True
        print("\nStopping (finishing current claim)...")

    signal.signal(signal.SIGINT, handle_stop)
    signal.signal(signal.SIGTERM, handle_stop)

    try:
        while not stop['flag'] and (args.count is None or stats['claims'] < args.count):
            added = world.maybe_grow(member_rate=args.new_member_rate,
                                      provider_rate=args.new_provider_rate,
                                      group_rate=args.new_group_rate)
            if added:
                log_growth(added)

            claim_lines = generate_claim(world, next_claim_id)

            if args.dry_run:
                for row in claim_lines:
                    print(row)
            else:
                try:
                    insert_claim(conn, args.schema, args.table, claim_lines)
                except psycopg2.Error as e:
                    print(f"  [warn] insert failed ({e}); reconnecting...", file=sys.stderr)
                    conn.close()
                    conn = connect_with_retry(args.dsn)
                    insert_claim(conn, args.schema, args.table, claim_lines)

            stats['claims'] += 1
            stats['lines'] += len(claim_lines)
            stats['billed'] += claim_lines[0]['claim_total_billed_amount']

            log_claim(claim_lines, verbose=args.verbose)
            if stats['claims'] % 25 == 0:
                log_summary(stats)

            next_claim_id += 1

            interval = 60.0 / args.rate
            jittered = interval * (1 + random.uniform(-args.jitter, args.jitter))
            sleep_remaining = max(jittered, 0.05)
            while sleep_remaining > 0 and not stop['flag']:
                nap = min(0.5, sleep_remaining)
                time.sleep(nap)
                sleep_remaining -= nap
    finally:
        log_summary(stats, final=True)
        if conn is not None:
            conn.close()


if __name__ == '__main__':
    main()

