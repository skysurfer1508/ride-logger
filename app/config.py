from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    session_secret: str
    db_path: str = "./data/ride_logger.db"

    oidc_client_id: str
    oidc_client_secret: str
    oidc_server_metadata_url: str
    oidc_redirect_uri: str

    # Ride segmentation tuning
    gap_minutes: float = 10
    min_points: int = 5
    min_distance_m: float = 200
    stale_trip_minutes: float = 60

    # Matching a ride's stops to traffic lights / signs from OpenStreetMap (app/osm.py). The server asks the public Overpass API for coarse map
    # tiles around the stops and caches them; the phone never talks to Overpass. Set OSM_ENABLED=false to turn the lookup off.
    osm_enabled: bool = True
    overpass_urls: str = "https://overpass-api.de/api/interpreter,https://overpass.private.coffee/api/interpreter"
    # The public Overpass servers ask for an identifying User-Agent: put a contact in it, e.g. "ride-logger/1.0 (you@example.com)".
    osm_user_agent: str = "ride-logger/1.0 (self-hosted)"

    # The app's Traffic tab. Both are optional and free; leave a key empty to switch that layer off (the app then says how to set it up).
    # Apple's own live traffic colours on the map need no key at all (MapKit draws them on the phone).
    #   opentransportdata_api_key: official Swiss traffic situations (accidents, congestion, roadworks), from https://api-manager.opentransportdata.swiss
    #   windy_api_key: public webcams near a spot, from https://api.windy.com/keys
    opentransportdata_api_key: str = ""
    windy_api_key: str = ""


settings = Settings()
