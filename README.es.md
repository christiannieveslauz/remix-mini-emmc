# Jide Remix Mini: Armbian arrancando desde la eMMC interna (sin microSD)

<p align="center"><a href="https://www.kickstarter.com/projects/jidetech/remix-mini-the-worlds-first-true-android-pc/faqs"><img src="assets/remix-mini.jpg" alt="Jide Remix Mini" width="580"></a><br><sub>Jide Remix Mini — campaña original en Kickstarter (2015). Imagen © Jide Technology.</sub></p>

*[Read in English](README.md)*

El **Jide Remix Mini** ([campaña original en Kickstarter](https://www.kickstarter.com/projects/jidetech/remix-mini-the-worlds-first-true-android-pc/faqs); modelo RM1G, Allwinner H64/A64, 1–2 GB de RAM, eMMC de 8/16 GB) fue un mini PC con Android de 2015 que terminó como chatarra electrónica: su chip tiene quemado el fusible de *secure boot* y rechaza los bootloaders estándar. Desde 2025 se puede arrancar Armbian desde una microSD con un bootloader comunitario, pero la eMMC interna se daba por inutilizable.

Este repositorio da el último paso: **un U-Boot firmado TOC0, compilado desde las fuentes oficiales, que arranca desde la eMMC**, y un script que pasa un Armbian en funcionamiento de la microSD a la eMMC. Resultado: un equipo ARM64 con Debian, sin ventilador y sin tarjeta.

**Estado:** funcionando en un Remix Mini 2 GB / 16 GB (RM1G) con Armbian 26.8.1 (Debian trixie, kernel 6.18.43), octubre de 2026. Probado en una unidad; se agradecen reportes.

## Qué funciona

| Componente | Estado |
|---|---|
| Arranque desde eMMC sin microSD | ✅ |
| Consola por HDMI | ✅ |
| WiFi (Realtek, 2,4 GHz) | ✅ |
| Puertos USB 2.0 | ✅ |
| 4 núcleos, 2 GB de RAM | ✅ |
| **Ethernet** | ❌ No soportado: el puerto de 100 Mbps usa un **X-Powers AC200**, sin driver en el kernel oficial; el devicetree lo deja deshabilitado. Usar WiFi o un adaptador USB-Ethernet (RTL8152/8153, ASIX). |
| Arrancar solo desde USB | ❌ Imposible: la ROM del chip solo conoce SD, eMMC y FEL. (El U-Boot de este repo busca en USB *después* de la eMMC, así que en teoría el sistema podría vivir en un pendrive; sin probar.) |

## Por qué hace falta

- La ROM de arranque solo acepta código envuelto en **TOC0** (el "secure boot" de Allwinner) e ignora las imágenes `eGON` comunes.
- No hay hash de clave grabado en los fusibles, así que **sirve cualquier clave RSA**: U-Boot puede generar la imagen TOC0 por sí mismo.
- El orden de arranque está fijo en la ROM: **microSD → eMMC → FEL**. Un TOC0 válido en la SD siempre gana, y eso vuelve seguro el procedimiento: si la eMMC no arranca, se pone la SD y listo.
- Linux oficial tiene el devicetree de la placa desde la v6.9 y U-Boot lo incluye en `dts/upstream`. El `remix-mini-pc_defconfig` propuesto en 2024 nunca se integró; este repo aporta uno.

## Procedimiento

Necesitás una microSD (≥ 8 GB, idealmente A1/A2), pantalla HDMI y teclado USB para el primer arranque, y una PC con Linux, WSL o Windows para preparar la tarjeta.

### 1. Arrancar Armbian desde la microSD (método comunitario)

Siguiendo el [gist de penzoiders](https://gist.github.com/penzoiders/582bfab2c9265716dd375fb5e7679bcf):

1. Grabar la **imagen de Armbian para Pine64** en la microSD (balenaEtcher, Rufus o `dd`). Si Windows ofrece formatearla después, decir que **no**.
2. Descargar el archivo `remixmini_boot_gap_8k_to_1m.bin` (enlaces en el gist) y escribirlo **a partir de los 8 KiB**:
   ```sh
   sudo dd if=remixmini_boot_gap_8k_to_1m.bin of=/dev/sdX bs=1024 seek=8 conv=fsync,notrunc
   ```
   En Windows, [`tools/write-boot-blob-windows.py`](tools/write-boot-blob-windows.py) hace lo mismo con controles de seguridad.
3. Arrancar el Remix Mini. Usuario inicial de Armbian: `root` / `1234`.

> Alternativa sin probar: escribir en la SD el U-Boot de este repo en lugar del archivo comunitario debería funcionar, porque soporta tanto MMC0 (SD) como MMC2 (eMMC). Si lo probás, abrí un issue con el resultado.

### 2. Usar el devicetree del Remix Mini

```sh
sudo nano /boot/armbianEnv.txt
# poner (o reemplazar) esta línea:
fdtfile=allwinner/sun50i-h64-remix-mini-pc.dtb
sudo reboot
```
Verificar: `cat /proc/device-tree/model` → `Remix Mini PC`.

### 3. Conectar el WiFi

La imagen minimal no trae `nmtui`: usar `armbian-config` → Network → WiFi, y seguir por SSH (mucho más cómodo que la consola con teclado en español).

### 4. Copiar este repo al equipo y correr el diagnóstico

```sh
git clone https://github.com/christiannieveslauz/remix-mini-emmc.git && cd remix-mini-emmc
sudo bash scripts/install-emmc.sh          # solo lectura
```
`PARTITION_CONFIG: 0x00` significa que las particiones de arranque de hardware de la eMMC no se usan: la ROM lee el bootloader del área de usuario en 8 KiB, donde está el de fábrica y donde va el nuevo.

### 5. Instalar

```sh
sudo bash scripts/install-emmc.sh --install
```
El script congela el paquete `linux-u-boot-*` de Armbian (una actualización regrabaría un bootloader de Pine64 sin TOC0), respalda **toda la eMMC** en `/root/emmc-original/` (unos 11 minutos), copia el sistema, ajusta `rootdev` y `fstab`, y graba el U-Boot. Después: `poweroff`, sacar la SD y encender.

Para volver a Remix OS: arrancar desde la SD y `sudo dd if=/root/emmc-original/emmc.img of=/dev/mmcblk2 bs=4M conv=fsync`.

## Compilar el U-Boot

```sh
./build.sh
```
Descarga commits fijos de U-Boot y Trusted Firmware-A, compila BL31 y U-Boot con [`configs/remix-mini-pc_defconfig`](configs/remix-mini-pc_defconfig). Cada compilación genera su propia clave RSA, así que **el checksum va a ser distinto** al del binario precompilado; es normal.

## Créditos

linux-sunxi y Andre Przywara (devicetree, soporte TOC0 y defconfig original), penzoiders (primer arranque desde SD), Matt Miller, r4nd3l y el foro de Armbian. Arranque desde eMMC: Christian Nieves ([christiannieves.uy](https://christiannieves.uy)).

Licencia GPL-2.0-or-later. Sin garantía: borra el Remix OS de fábrica de la eMMC (antes hace un respaldo completo).
