-- =====================================================================
-- OLX Used Goods Marketplace Database: Data Ingestion Script
-- Loads seed data into olx schema in foreign key dependency order.
-- =====================================================================

SET search_path TO olx;

\echo 'Loading cities...'
\copy cities FROM 'seed_data/cities.csv' WITH (FORMAT csv, HEADER true);

\echo 'Loading categories...'
\copy categories FROM 'seed_data/categories.csv' WITH (FORMAT csv, HEADER true);

\echo 'Loading boost_packages...'
\copy boost_packages FROM 'seed_data/boost_packages.csv' WITH (FORMAT csv, HEADER true);

\echo 'Loading users...'
\copy users FROM 'seed_data/users.csv' WITH (FORMAT csv, HEADER true);

\echo 'Loading listings...'
\copy listings FROM 'seed_data/listings.csv' WITH (FORMAT csv, HEADER true);

\echo 'Loading chat_threads...'
\copy chat_threads FROM 'seed_data/chat_threads.csv' WITH (FORMAT csv, HEADER true);

\echo 'Loading chat_messages...'
\copy chat_messages FROM 'seed_data/chat_messages.csv' WITH (FORMAT csv, HEADER true);

\echo 'Loading offers...'
\copy offers FROM 'seed_data/offers.csv' WITH (FORMAT csv, HEADER true);

\echo 'Loading favourites...'
\copy favourites FROM 'seed_data/favourites.csv' WITH (FORMAT csv, HEADER true);

\echo 'Loading reports...'
\copy reports FROM 'seed_data/reports.csv' WITH (FORMAT csv, HEADER true);

\echo 'Loading seller_ratings...'
\copy seller_ratings FROM 'seed_data/seller_ratings.csv' WITH (FORMAT csv, HEADER true);

\echo 'Running ANALYZE on all tables...'
ANALYZE;

\echo 'Data load complete. Row count verification:'
SELECT 'cities' AS table_name, count(*) AS total_rows FROM cities
UNION ALL SELECT 'categories', count(*) FROM categories
UNION ALL SELECT 'boost_packages', count(*) FROM boost_packages
UNION ALL SELECT 'users', count(*) FROM users
UNION ALL SELECT 'listings', count(*) FROM listings
UNION ALL SELECT 'chat_threads', count(*) FROM chat_threads
UNION ALL SELECT 'chat_messages', count(*) FROM chat_messages
UNION ALL SELECT 'offers', count(*) FROM offers
UNION ALL SELECT 'favourites', count(*) FROM favourites
UNION ALL SELECT 'reports', count(*) FROM reports
UNION ALL SELECT 'seller_ratings', count(*) FROM seller_ratings;
