DROP SCHEMA IF EXISTS claims_source CASCADE;

CREATE SCHEMA claims_source;

CREATE TABLE claims_source.claim_events (
    -- ---- event metadata -------------------------------------------------
    event_id                            BIGSERIAL       PRIMARY KEY,
    event_type                          VARCHAR(10)     NOT NULL DEFAULT 'INSERT',  -- INSERT, UPDATE, DELETE
    event_ts                            TIMESTAMPTZ     NOT NULL DEFAULT now(),

    -- ---- claim_line grain identifiers ------------------------------------
    claim_id                            BIGINT          NOT NULL,
    line_number                         SMALLINT        NOT NULL,

    -- ---- claim_header ------------------------------------------------
    claim_type                          VARCHAR(15),        -- Professional, Institutional, Dental, Pharmacy
    claim_status                        VARCHAR(15),        -- Paid, Denied, Pending, Reversed
    claim_is_preventative               BOOLEAN,            -- true iff every line is a preventative procedure (checkup, vaccine)
    received_date                       DATE,
    service_date_start                  DATE,
    service_date_end                    DATE,
    paid_date                           DATE,
    claim_total_billed_amount           NUMERIC(12,2),
    claim_total_allowed_amount          NUMERIC(12,2),
    claim_total_paid_amount             NUMERIC(12,2),
    claim_total_member_resp_amount      NUMERIC(12,2),

    -- ---- claim_line --------------------------------------------------
    line_service_date                   DATE,
    place_of_service                    VARCHAR(5),
    modifier_code                       VARCHAR(5),
    units                                SMALLINT,
    line_billed_amount                  NUMERIC(10,2),
    line_allowed_amount                 NUMERIC(10,2),
    line_paid_amount                    NUMERIC(10,2),
    line_copay_amount                   NUMERIC(10,2),
    line_coinsurance_amount             NUMERIC(10,2),
    line_deductible_amount              NUMERIC(10,2),
    line_status                          VARCHAR(15),       -- Paid, Denied

    -- ---- members (the insured person) --------------------------------
    member_id                           INTEGER,
    member_subscriber_id                VARCHAR(20),
    member_first_name                   VARCHAR(50),
    member_last_name                    VARCHAR(50),
    member_date_of_birth                DATE,
    member_gender                       CHAR(1),
    member_relationship_code            VARCHAR(15),        -- Subscriber, Spouse, Dependent
    member_plan_type                    VARCHAR(10),        -- HMO, PPO, EPO, HDHP
    member_address_line1                VARCHAR(100),
    member_city                         VARCHAR(50),
    member_state                        CHAR(2),
    member_zip_code                     VARCHAR(10),
    member_effective_date               DATE,
    member_termination_date             DATE,

    -- ---- groups (insurance group / plan sponsor) ----------------------
    group_id                            INTEGER,
    group_name                          VARCHAR(100),
    group_type                          VARCHAR(30),        -- Employer, Individual, Government, Association
    group_funding_type                  VARCHAR(20),        -- Fully Insured, Self Funded
    group_industry_sic                  VARCHAR(10),
    group_state                         CHAR(2),
    group_effective_date                DATE,
    group_termination_date              DATE,

    -- ---- providers: billing provider on the claim ---------------------
    billing_provider_id                 INTEGER,
    billing_provider_npi                VARCHAR(10),
    billing_provider_name               VARCHAR(100),
    billing_provider_type               VARCHAR(20),        -- Individual, Facility, Group
    billing_provider_taxonomy_code      VARCHAR(10),
    billing_provider_specialty_desc     VARCHAR(60),
    billing_provider_state              CHAR(2),
    billing_provider_network_status     VARCHAR(15),        -- In-Network, Out-of-Network

    -- ---- providers: rendering provider on this line --------------------
    rendering_provider_id               INTEGER,
    rendering_provider_npi              VARCHAR(10),
    rendering_provider_name             VARCHAR(100),
    rendering_provider_specialty_desc   VARCHAR(60),
    rendering_provider_state            CHAR(2),
    rendering_provider_network_status   VARCHAR(15),

    -- ---- diagnosis on this line ----------------------------------------
    diagnosis_id                        INTEGER,
    diagnosis_code                      VARCHAR(10),        -- ICD-10-CM
    diagnosis_desc                      VARCHAR(255),
    diagnosis_category                  VARCHAR(60),
    diagnosis_chronic_flag              BOOLEAN,

    -- ---- procedure on this line -----------------------------------------
    procedure_id                        INTEGER,
    procedure_code                      VARCHAR(10),        -- CPT / HCPCS
    procedure_desc                      VARCHAR(255),
    procedure_category                  VARCHAR(60),
    procedure_code_type                 VARCHAR(10),        -- CPT, HCPCS
    procedure_is_preventative           BOOLEAN,            -- true for wellness visits, immunizations, etc.

    CONSTRAINT uq_claim_events_claim_line UNIQUE (claim_id, line_number)
);

COMMENT ON TABLE claims_source.claim_events IS
    'Denormalized, claim-line-grain feed of incoming claims -- a stand-in for an upstream OLTP source system that a CDC/ETL process would read and fan out into the normalized claims_demo schema.';

-- Helpful indexes for a "new since last checkpoint" consumer and for
-- typical demo queries/joins.
CREATE INDEX ix_claim_events_event_ts        ON claims_source.claim_events (event_ts);
CREATE INDEX ix_claim_events_claim_id        ON claims_source.claim_events (claim_id);
CREATE INDEX ix_claim_events_member_id       ON claims_source.claim_events (member_id);
CREATE INDEX ix_claim_events_group_id        ON claims_source.claim_events (group_id);
CREATE INDEX ix_claim_events_service_date    ON claims_source.claim_events (service_date_start);
CREATE INDEX ix_claim_events_diagnosis_code  ON claims_source.claim_events (diagnosis_code);
CREATE INDEX ix_claim_events_procedure_code  ON claims_source.claim_events (procedure_code);
