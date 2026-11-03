from fastapi import APIRouter, HTTPException
from app.core.logger import logger

router = APIRouter(prefix="/boom", tags=["boom"])


@router.get("/", summary=" Endpoint de prueba que devuelve 500")
def boom():
    """ Endpoint intencionalmente roto para la demostracion de rollback ."""

    raise HTTPException(status_code=500, detail="boom")
