"""Pydantic models for the Overland-iOS ingest payload.

Field names and shape are taken directly from the Overland-iOS source
(GPSLogger/GLManager.m) and README, not guessed. Models are permissive
(extra="allow") because Overland has added fields across versions and we
don't want an unrecognized field to reject an otherwise-valid batch.
"""

from typing import Any, Optional

from pydantic import BaseModel, ConfigDict


class Geometry(BaseModel):
    model_config = ConfigDict(extra="allow")

    type: str
    coordinates: list[float]  # [longitude, latitude]


class LocationProperties(BaseModel):
    model_config = ConfigDict(extra="allow")

    timestamp: str
    type: Optional[str] = None  # "trip" marks a trip-end summary, not a normal point
    altitude: Optional[float] = None
    speed: Optional[float] = None
    horizontal_accuracy: Optional[float] = None
    vertical_accuracy: Optional[float] = None
    motion: Optional[list[str]] = None
    battery_state: Optional[str] = None
    battery_level: Optional[float] = None
    device_id: Optional[str] = ""
    wifi: Optional[str] = None
    trip_id: Optional[str] = None

    # Present only when properties.type == "trip" (trip-end summary marker)
    mode: Optional[str] = None
    start: Optional[str] = None
    end: Optional[str] = None
    start_location: Optional[dict[str, Any]] = None
    end_location: Optional[dict[str, Any]] = None
    duration: Optional[float] = None
    distance: Optional[float] = None
    stopped_automatically: Optional[bool] = None


class LocationFeature(BaseModel):
    model_config = ConfigDict(extra="allow")

    type: str
    geometry: Geometry
    properties: LocationProperties
