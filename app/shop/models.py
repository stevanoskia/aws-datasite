"""What a request may contain. Anything else is refused before it reaches the database."""

from datetime import UTC, date, datetime, time, timedelta
from typing import Annotated, Literal
from uuid import UUID

from fastapi import HTTPException, Path, Query
from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator

BIGINT_MAX = 2**63 - 1
INTEGER_MAX = 2**31 - 1

Id = Annotated[int, Path(ge=1, le=BIGINT_MAX)]
BodyId = Annotated[int, Field(ge=1, le=BIGINT_MAX)]
CategoryId = Annotated[int | None, Query(ge=1, le=INTEGER_MAX)]
Page = Annotated[int, Query(ge=1, le=100_000)]
PageSize = Annotated[int, Query(ge=1, le=100)]
Limit = Annotated[int, Query(ge=1, le=100)]
NO_ZERO_CHARACTER = r"^[^\x00]*$"  # PostgreSQL text can't hold it
Text = StringConstraints(strip_whitespace=True, pattern=NO_ZERO_CHARACTER)
Day = Annotated[date | None, Query(ge=date(2000, 1, 1), le=date(2100, 1, 1))]

OrderStatus = Literal["pending", "paid", "shipped", "delivered", "cancelled", "returned"]


class Body(BaseModel):
    model_config = ConfigDict(extra="forbid")


class OrderLine(Body):
    product_id: BodyId
    quantity: int = Field(ge=1, le=100)


class NewOrder(Body):
    customer_id: BodyId
    payment_method: Literal["card", "paypal", "bank_transfer", "gift_card"]
    lines: list[OrderLine] = Field(min_length=1, max_length=20)

    @model_validator(mode="after")
    def each_product_once(self) -> NewOrder:
        if len({line.product_id for line in self.lines}) != len(self.lines):
            raise ValueError("each product may appear only once")
        return self


class StatusChange(Body):
    status: OrderStatus


class NewReview(Body):
    customer_id: BodyId
    rating: int = Field(ge=1, le=5)
    title: Annotated[str, Text, Field(min_length=1, max_length=200)]
    body: Annotated[str, Text, Field(max_length=5000)] = ""


class NewEvent(Body):
    event_type: Literal["view", "search", "add_to_cart", "checkout", "login"]
    session_id: UUID
    customer_id: BodyId | None = None
    product_id: BodyId | None = None
    payload: dict[Annotated[str, Text, Field(max_length=50)], Annotated[str, Text, Field(max_length=200)]] = Field(
        default_factory=dict, max_length=20
    )


class Period:
    """A range of days in UTC: start is included, end is not. Without values: the last 30 days."""

    def __init__(self, start: Day = None, end: Day = None) -> None:
        self.end_day = end or datetime.now(UTC).date() + timedelta(days=1)
        self.start_day = start or self.end_day - timedelta(days=30)
        if not timedelta(0) < self.end_day - self.start_day <= timedelta(days=366):
            raise HTTPException(422, "the period must be 1 to 366 days long")
        self.start = datetime.combine(self.start_day, time(), UTC)
        self.end = datetime.combine(self.end_day, time(), UTC)
