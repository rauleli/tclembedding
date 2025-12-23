-- Estructura de prueba para el RAG
CREATE TABLE IF NOT EXISTS youtube_test (
    id INT AUTO_INCREMENT PRIMARY KEY,
    categoria ENUM('transcripcion', 'metadatos', 'comentario'),
    contenido TEXT,
    embedding BINARY(1536), -- 384 floats * 4 bytes
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;
