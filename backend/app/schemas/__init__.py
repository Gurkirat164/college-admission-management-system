from typing import Literal

from pydantic import BaseModel, Field


class Login(BaseModel):
    email: str = Field(min_length=3, max_length=254)
    password: str = Field(min_length=1, max_length=200)


class Register(Login):
    full_name: str = Field(min_length=2, max_length=100)


class Choices(BaseModel):
    program_ids: list[int] = Field(max_length=30)


class Simulation(BaseModel):
    round_id: int
    base_sim_id: int | None = None
    scenario: dict = Field(default_factory=dict)


class ResponseDecision(BaseModel):
    decision: Literal["FREEZE", "FLOAT", "SLIDE", "WITHDRAW"]


class SeatChange(BaseModel):
    seats: int = Field(ge=0, le=10000)


class SpotRequest(BaseModel):
    pool_id: int
    idempotency_key: str = Field(min_length=8, max_length=100)
