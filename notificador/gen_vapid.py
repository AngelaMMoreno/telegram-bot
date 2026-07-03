"""
Genera un par de claves VAPID (P-256) y las imprime en un formato listo
para pegar en las variables de entorno del stack.

Uso local (sin dependencias del stack):

    python3 -m venv .venv && . .venv/bin/activate
    pip install py-vapid
    python gen_vapid.py

Salida esperada:

    VAPID_PRIVATE_KEY="MHcCAQEE...\\n-----BEGIN..."   (todo en una línea, con \\n)
    VAPID_PUBLIC_KEY="BFm..."                          (base64url, sin padding)

- La PRIVATE se pasa al notificador (secret; no aparece nunca en el navegador).
- La PUBLIC se guarda en config.push_vapid_public para que la SPA la lea
  con push_config_publica() al suscribirse.

Regenerar las claves invalida todas las suscripciones ya existentes: los
navegadores tendrán que re-suscribirse. Solo hacerlo si se filtró la privada.
"""
from __future__ import annotations

from py_vapid import Vapid01


def main() -> None:
    v = Vapid01()
    v.generate_keys()

    # Privada: PEM de una sola línea (los saltos son "\n" literales).
    pem = v.private_pem().decode("utf-8").replace("\n", "\\n")

    # Pública: base64url según spec Web Push.
    pub_raw = v.public_key.public_bytes(
        encoding=__import__("cryptography").hazmat.primitives.serialization.Encoding.X962,
        format=__import__("cryptography").hazmat.primitives.serialization.PublicFormat.UncompressedPoint,
    )
    import base64
    pub_b64 = base64.urlsafe_b64encode(pub_raw).rstrip(b"=").decode()

    print()
    print("# Copia estas dos variables a .env / secretos del stack:")
    print(f'VAPID_PRIVATE_KEY="{pem}"')
    print(f'VAPID_PUBLIC_KEY="{pub_b64}"')
    print()
    print("# Y actualiza en la BBDD la clave pública para la SPA:")
    print("#   UPDATE config SET valor = jsonb_build_object("
          "'valor', %L, 'descripcion', valor->>'descripcion') "
          "WHERE clave = 'push_vapid_public';".replace("%L", f"'{pub_b64}'"))


if __name__ == "__main__":
    main()
