CREATE SCHEMA IF NOT EXISTS analytics;
CREATE TABLE IF NOT EXISTS profiles (
    id UUID PRIMARY KEY DEFAULT uuid(),
    name TEXT NOT NULL,
    email TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    color TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS sessions (
    id UUID PRIMARY KEY DEFAULT uuid(),
    profile_id UUID NOT NULL,
    token TEXT UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP NOT NULL,
    FOREIGN KEY (profile_id) REFERENCES profiles (id)
);
CREATE TABLE IF NOT EXISTS vehicles (
    id UUID PRIMARY KEY DEFAULT uuid(),
    profile_id UUID NOT NULL,
    make TEXT NOT NULL,
    model TEXT NOT NULL,
    year INTEGER NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (profile_id) REFERENCES profiles (id)
);
CREATE TABLE IF NOT EXISTS geocode_cache (
    address_hash TEXT PRIMARY KEY,
    address_raw TEXT NOT NULL,
    latitude DECIMAL(8, 6) NOT NULL,
    longitude DECIMAL(9, 6) NOT NULL,
    raw_response JSON NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS route_cache (
    from_lat decimal(8, 6) NOT NULL,
    from_lng decimal(9, 6) NOT NULL,
    to_lat decimal(8, 6) NOT NULL,
    to_lng decimal(9, 6) NOT NULL,
    distance_meters INTEGER NOT NULL,
    duration_seconds INTEGER NOT NULL,
    geometry_geojson JSON,
    raw_response JSON,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (from_lat, from_lng, to_lat, to_lng)
);
CREATE TABLE IF NOT EXISTS receipts (
    id UUID NOT NULL PRIMARY KEY,
    profile_id UUID NOT NULL,
    vehicle_id UUID NOT NULL,
    created_at TIMESTAMP NOT NULL,
    updated_at TIMESTAMP NOT NULL,
    image_path VARCHAR(1024) NOT NULL,
    status VARCHAR NOT NULL CHECK (
        status IN (
            'uploaded',
            'processing',
            'needs_review',
            'failed',
            'confirmed'
        )
    ),
    error_message VARCHAR,
    raw_llm_response JSON,
    station_name VARCHAR(255),
    station_address VARCHAR(512),
    latitude DECIMAL(9, 6),
    longitude DECIMAL(9, 6),
    receipt_date DATE,
    fuel_type VARCHAR(64),
    volume_liters DECIMAL(10, 3),
    price_per_liter DECIMAL(10, 3),
    total_amount DECIMAL(10, 2),
    currency VARCHAR(3) NOT NULL DEFAULT 'EUR',
    field_confidence JSON,
    is_user_confirmed BOOLEAN NOT NULL DEFAULT FALSE,
    confirmed_at TIMESTAMP,
    FOREIGN KEY (profile_id) REFERENCES profiles (id),
    FOREIGN KEY (vehicle_id) REFERENCES vehicles (id)
);