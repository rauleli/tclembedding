# TODO - RAG & MySQL Optimizations Project

This document details pending improvements, hardware optimizations, and planned new features for the information retrieval (RAG) system.

## Performance Optimizations (Hardware & C)

- [ ] **Runtime CPU Dispatching:** Evolve the C code to detect capabilities (SSE/AVX) at runtime instead of relying solely on compile-time flags.
- [ ] **Vector Pre-normalization:** Modify the Tcl ingestion flow to normalize vectors to magnitude 1.0. This will allow using a simple *Dot Product* in MySQL, skipping square root calculations and divisions.
- [ ] **Quantization Support (INT8):** Research and implement similarity calculation on quantized vectors to reduce memory footprint in MySQL and increase speed on older CPUs.
- [ ] **Latency Benchmarking:** Create a script to measure `cosine_similarity` response time scaling from 10k to 1M records on the Phenom II.

## RAG Engine Improvements

- [ ] **Re-ranking with Cross-Encoders:** Implement a second filtering stage after semantic search in MySQL to improve response accuracy.
- [ ] **Dynamic Context Management:** Optimize the number of chunks sent to the LLM based on the similarity score obtained from the UDF.
- [ ] **Multi-Model Support:** Allow configuration of different embedding models (e.g., BGE or larger E5 versions) by dynamically adjusting the UDF to new dimensions.

## Tools and Maintenance

- [ ] **Build Automation:** Create a robust `Makefile` that detects the system architecture and applies GCC flags (`-march=native`, `-lm`, etc.) automatically.
- [ ] **Diagnostic Scripts:** Develop a Tcl tool that verifies the integrity of embeddings stored in the database.
- [ ] **API Documentation:** Expand the `.md` files with clear examples of how to consume the UDF from languages other than Tcl.

## Scalability

- [ ] **Migration to Vector Indexes:** If the table exceeds one million records, evaluate integration of tools like `pgvector` (in case of migrating to Postgres) or the use of spatial indexes in MySQL for pre-filtering.

---
*Last updated: December 2025 - SSE4A Hardware Optimization completed.*
