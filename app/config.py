import os


class Settings:
    app_name: str = "TaskBoard"
    # Строка подключения берётся из переменной окружения DATABASE_URL
    # (её выставляет deploy.sh). Если переменная не задана - значение по умолчанию.
    database_url: str = os.getenv(
        "DATABASE_URL",
        "postgresql+psycopg://taskboard:taskboard@localhost:5432/taskboard",
    )


settings = Settings()
