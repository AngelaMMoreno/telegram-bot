"""
Genera un par de claves VAPID (P-256) y lo imprime en varios formatos, para
que puedas pegarlo en el gestor de secretos que uses (Dokploy, GitHub
Actions, .env local…).

Uso:

    pip install py-vapid
    python gen_vapid.py

El worker (notificador.py → _normalizar_vapid_key) acepta la privada en:

  1. PEM con saltos REALES (multilínea)
  2. PEM con '\\n' LITERALES en una sola línea      ← recomendado para .env
  3. Base64 del PEM entero                          ← más robusto de pegar

Regenerar las claves invalida las suscripciones ya existentes: los
navegadores tendrán que re-suscribirse. Solo hacerlo si se filtró la privada.
"""
from __future__ import annotations

import base64

from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from py_vapid import Vapid01


def main() -> None:
    v = Vapid01()
    v.generate_keys()

    pem_multilinea = v.private_pem().decode("utf-8")
    pem_una_linea  = pem_multilinea.replace("\n", "\\n")
    pem_b64        = base64.b64encode(pem_multilinea.encode("utf-8")).decode()

    pub_raw = v.public_key.public_bytes(
        encoding=Encoding.X962,
        format=PublicFormat.UncompressedPoint,
    )
    pub_b64 = base64.urlsafe_b64encode(pub_raw).rstrip(b"=").decode()

    line = "─" * 72
    print()
    print(line)
    print(" CLAVE PÚBLICA (segura de compartir)")
    print(line)
    print(f'VAPID_PUBLIC_KEY="{pub_b64}"')
    print()
    print("# Guarda esta misma clave pública en la BBDD para que la SPA la lea:")
    print("UPDATE config")
    print("   SET valor = jsonb_build_object(")
    print(f"       'valor', '{pub_b64}',")
    print("       'descripcion', valor->>'descripcion')")
    print(" WHERE clave = 'push_vapid_public';")
    print()
    print(line)
    print(" CLAVE PRIVADA — elige UNA de estas variantes según tu UI de secretos")
    print(line)
    print()
    print("── (A) Recomendado para Dokploy / .env: una sola línea con \\n literales")
    print(f'VAPID_PRIVATE_KEY="{pem_una_linea}"')
    print()
    print("── (B) Base64 del PEM entero: no contiene '/' problemáticos ni saltos")
    print(f'VAPID_PRIVATE_KEY="{pem_b64}"')
    print()
    print("── (C) PEM multilínea: solo si tu UI acepta valores con saltos reales")
    print(pem_multilinea)
    print(line)


if __name__ == "__main__":
    main()
