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

    # Map matching and routing (deploy/valhalla). Empty switches the speed-limit check and the route planner off.
    valhalla_url: str = "http://127.0.0.1:8002"
    weather_enabled: bool = True          # Open-Meteo, no key. False sends no ride position anywhere
    # Twisty-road database for the Roads layer (built by `python -m app.cli build-roads`, see ios/README.md). Missing file: the layer says so.
    roads_db_path: str = "./data/roads.db"

    # The app's Traffic tab. Both are optional and free; leave a key empty to switch that layer off (the app then says how to set it up).
    # Apple's own live traffic colours on the map need no key at all (MapKit draws them on the phone).
    #   opentransportdata_api_key: official Swiss traffic situations (accidents, congestion, roadworks), from https://api-manager.opentransportdata.swiss
    #   windy_api_key: public webcams near a spot, from https://api.windy.com/keys
    opentransportdata_api_key: str = ""
    windy_api_key: str = ""

    # The natural navigation voice (app/voice.py): Piper, a local neural text-to-speech, renders the spoken phrases to mp3 and the phone caches them. Not set up
    # (no piper package or no model files) the app falls back to the phone's own voice. Set up with deploy/voice/setup.sh.
    voice_enabled: bool = True
    voice_dir: str = "./data/voice"                       # rendered clips
    voice_models_dir: str = "./data/voice-models"         # <name>.onnx and <name>.onnx.json per voice
    voice_en_model: str = "en_US-ryan-high"             # the English voice (instructions, distances)
    voice_de_model: str = "de_DE-thorsten-medium"         # the German voice (Swiss street names)


settings = Settings()
