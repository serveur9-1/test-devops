"""Task Manager API - FastAPI + sqlite3 (bibliothèque standard)."""

import os
import sqlite3
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

DEFAULT_DATABASE_PATH = "tasks.db"


def database_path():
    # Relu à chaque appel, pour que les tests puissent surcharger DATABASE_PATH.
    return os.environ.get("DATABASE_PATH", DEFAULT_DATABASE_PATH)


class TaskIn(BaseModel):
    title: str = Field(min_length=1, max_length=200)


class Task(BaseModel):
    id: int
    title: str


def get_connection():
    connection = sqlite3.connect(database_path())
    connection.row_factory = sqlite3.Row  # accès aux colonnes par nom
    return connection


def init_db():
    with get_connection() as connection:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS tasks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL
            )
            """
        )


@asynccontextmanager
async def lifespan(_app: FastAPI):
    # Schéma créé au démarrage : le projet n'utilise pas d'outil de migration.
    init_db()
    yield


app = FastAPI(title="Task Manager API", version="1.0.0", lifespan=lifespan)


@app.get("/health")
def health():
    """Liveness : l'application répond."""
    return {"status": "ok"}


@app.get("/ready")
def ready():
    """Readiness : la base de données est accessible."""
    try:
        with get_connection() as connection:
            connection.execute("SELECT 1")
    except sqlite3.Error:
        raise HTTPException(status_code=503, detail="database unavailable")
    return {"status": "ready"}


@app.get("/tasks", response_model=list[Task])
def list_tasks():
    """Liste les tâches, la plus récente en premier."""
    with get_connection() as connection:
        rows = connection.execute(
            "SELECT id, title FROM tasks ORDER BY id DESC"
        ).fetchall()
    return [{"id": row["id"], "title": row["title"]} for row in rows]


@app.post("/tasks", response_model=Task, status_code=201)
def create_task(task: TaskIn):
    """Crée une tâche ; le titre est débarrassé des espaces superflus."""
    title = task.title.strip()
    # min_length=1 laisse passer un titre composé uniquement d'espaces.
    if not title:
        raise HTTPException(status_code=422, detail="title must not be empty")

    with get_connection() as connection:
        cursor = connection.execute(
            "INSERT INTO tasks (title) VALUES (?)", (title,)
        )
    return {"id": cursor.lastrowid, "title": title}


@app.delete("/tasks/{task_id}", status_code=204)
def delete_task(task_id: int):
    """Supprime une tâche, 404 si elle n'existe pas."""
    with get_connection() as connection:
        cursor = connection.execute("DELETE FROM tasks WHERE id = ?", (task_id,))
        if cursor.rowcount == 0:
            raise HTTPException(status_code=404, detail="task not found")
    return None
