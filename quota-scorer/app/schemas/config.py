from pydantic import BaseModel


class PrometheusParams(BaseModel):
    query: str
    range: int
    step: int


class SourceConfig(BaseModel):
    type: str
    host: str
    path: str
    params: PrometheusParams


class ScoringParams(BaseModel):
    name: str
    interval: int


class ScoringConfig(BaseModel):
    # In-cluster Service URL so every managed cluster scores locally
    # (not via the hub configURL Route host).
    host: str
    path: str
    params: ScoringParams


class ConfigResponse(BaseModel):
    name: str
    description: str
    source: SourceConfig
    scoring: ScoringConfig
