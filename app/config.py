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


settings = Settings()
