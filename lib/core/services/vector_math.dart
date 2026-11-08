import 'dart:math';

/// Utility for vector math and RAG retrieval calculations.
class VectorMath {
  /// Computes the cosine similarity between two float vectors.
  /// Returns a value between -1.0 and 1.0 (typically 0.0 to 1.0 for normalized text embeddings).
  static double cosineSimilarity(List<double> a, List<double> b) {
    if (a.isEmpty || b.isEmpty || a.length != b.length) return 0.0;
    double dotProduct = 0.0;
    double normA = 0.0;
    double normB = 0.0;
    for (int i = 0; i < a.length; i++) {
      dotProduct += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA == 0.0 || normB == 0.0) return 0.0;
    return dotProduct / (sqrt(normA) * sqrt(normB));
  }
}