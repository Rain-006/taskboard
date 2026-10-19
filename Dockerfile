# Образ для запуска приложения TaskBoard (FastAPI + Uvicorn).
# PostgreSQL в образ не входит: он запускается отдельным контейнером.

# Базовый образ: Python 3.13 (по требованию лабораторной) в облегчённой версии
FROM python:3.13-slim

# Не создавать .pyc-файлы и сразу выводить логи в консоль
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Рабочая директория внутри контейнера
WORKDIR /app

# Сначала копируем только requirements.txt: так слой с зависимостями
# кэшируется и не пересобирается при каждом изменении кода
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Копируем код приложения
COPY app ./app
COPY templates ./templates
COPY static ./static

# Строка подключения к БД (читается в app/config.py).
# По умолчанию БД ожидается в контейнере с именем "db"; можно переопределить через -e
ENV DATABASE_URL=postgresql+psycopg://taskboard:taskboard@db:5432/taskboard

# Запуск не от root
RUN useradd --create-home appuser
USER appuser

# Приложение слушает порт 8000
EXPOSE 8000

# Команда запуска
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
