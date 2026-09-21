SELECT * FROM pgfs.list_storage_locations();

SELECT bdr.alter_node_group_option('group1', 'analytics_storage_location', NULL);
SELECT bdr.alter_node_group_option('group1', 'analytics_storage_location', 'pgaa-demo');
SELECT bdr.alter_node_group_option('group1', 'analytics_write_catalog', NULL);

--ALTER TABLE claims_source.claim_events SET (pgd.replicate_to_analytics = false, pgd.purge_analytics_target = true);
ALTER TABLE claims_source.claim_events SET (pgd.replicate_to_analytics = true, pgd.purge_analytics_target = true);
