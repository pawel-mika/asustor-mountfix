#!/bin/sh

# Sprawdzenie liczby argumentów
if [ "$#" -ne 2 ]; then
    echo "Użycie: $0 <źródło> <cel>"
    exit 1
fi

SOURCE="$1"
DEST="$2"

# Sprawdzenie czy źródło istnieje
if [ ! -d "$SOURCE" ]; then
    echo "Błąd: Folder źródłowy '$SOURCE' nie istnieje."
    exit 1
fi

# Jeśli cel istnieje, usuwamy go (nadpisywanie)
if [ -d "$DEST" ]; then
    rm -rf "$DEST"
fi

# Kopiowanie folderu
# Tworzymy katalog nadrzędny dla celu, jeśli nie istnieje
mkdir -p "$(dirname "$DEST")"
cp -R "$SOURCE" "$DEST"

if [ $? -eq 0 ]; then
    echo "Migracja zakończona pomyślnie: $SOURCE -> $DEST"
else
    echo "Błąd podczas kopiowania."
    exit 1
fi

