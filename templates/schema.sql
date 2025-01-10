CREATE TABLE user_profiles (
    id SERIAL PRIMARY KEY,
    cognito_sub TEXT UNIQUE NOT NULL, -- Cognito's user ID
    region TEXT,
    preferred_currency TEXT DEFAULT 'USD',
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE transactions (
    id SERIAL PRIMARY KEY,
    user_id INT REFERENCES user_profiles(id),
    transaction_hash TEXT NOT NULL,
    amount DECIMAL(18, 8) NOT NULL,
    status TEXT DEFAULT 'pending',
    metadata JSONB,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP
);

CREATE TABLE transaction_events (
    id SERIAL PRIMARY KEY,
    transaction_id INT REFERENCES transactions(id),
    event_type TEXT NOT NULL,
    details JSONB,
    created_at TIMESTAMP DEFAULT NOW()
);

