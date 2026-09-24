# Personal OS

Personal OS est une application locale macOS composée de deux processus :

```text
Personal OS
├── mac-detective  → SQLite/WAL + statut runtime JSON local
└── Dashboard      → lecture SwiftUI read-only
```

Le Dashboard ne démarre pas mac-detective, ne modifie pas la base et ne dépend
d'aucun service réseau. Le launcher fournit une commande unique pour démarrer
les deux composants, surveiller leur cycle de vie et les arrêter ensemble.

## Construction

Depuis la racine du repository :

```sh
./scripts/build-personal-os.sh
```

Le script construit séparément `apps/mac-detective` puis `apps/dashboard`.
Une erreur Swift n'est pas masquée : le code de sortie du script est celui de
la commande ayant échoué.

## Lancement

```sh
./scripts/start-personal-os.sh
```

Le launcher :

1. vérifie les binaires et construit automatiquement les composants absents ;
2. crée `.runtime/personal-os` (ignoré par Git) ;
3. démarre mac-detective sans lancer `sudo` implicitement (`fs_usage` est désactivé par défaut) ;
4. attend une base SQLite, un statut runtime valide et une première persistence ;
5. démarre le Dashboard avec exactement les mêmes chemins ;
6. surveille les deux processus ;
7. arrête et nettoie les deux processus sur `Ctrl+C` ou `TERM`.

Un second launcher ne peut pas démarrer une instance concurrente. Les logs
respectifs sont disponibles dans :

```text
.runtime/personal-os/mac-detective.log
.runtime/personal-os/dashboard.log
```

Le lancement direct reste possible pour le développement :

```sh
swift run --package-path apps/dashboard
```

## Configuration locale

Les deux applications utilisent les variables suivantes :

| Variable | Rôle | Valeur par défaut du launcher |
| --- | --- | --- |
| `MAC_DETECTIVE_DATABASE` | Base SQLite locale | `.runtime/personal-os/mac_detective.sqlite` |
| `MAC_DETECTIVE_RUNTIME_STATUS` | Statut runtime JSON local | `.runtime/personal-os/.mac-detective-runtime-status.json` |
| `PERSONAL_OS_RUNTIME_DIR` | Répertoire de runtime et logs | `.runtime/personal-os` |
| `PERSONAL_OS_ROOT` | Racine repository transmise aux composants | racine du launcher |
| `MAC_DETECTIVE_FS_USAGE` | Activer explicitement `fs_usage` (nécessite des permissions) | `0` |

Les chemins relatifs du launcher sont résolus depuis la racine du repository.
Les deux processus reçoivent les mêmes chemins absolus. Exemple :

```sh
MAC_DETECTIVE_DATABASE="$PWD/data/database/mac_detective.sqlite" \
MAC_DETECTIVE_RUNTIME_STATUS="$PWD/data/database/.mac-detective-runtime-status.json" \
./scripts/start-personal-os.sh
```

`fs_usage` reste désactivé par défaut. Une activation volontaire peut être
faite avec `MAC_DETECTIVE_FS_USAGE=1`; le launcher ne l'active jamais tout seul
et n'exécute pas `sudo` automatiquement.

Les chemins sont configurables pour ne pas dépendre d'un nom de compte ou
d'un chemin personnel codé en dur. `PERSONAL_OS_START_TIMEOUT` et
`PERSONAL_OS_SHUTDOWN_TIMEOUT` permettent d'ajuster les attentes du launcher.

## Dashboard

La navigation native macOS propose :

- **Overview** : CPU, RAM, disk, network, runtime, dernier cycle, persistence et maintenance ;
- **History** : 15 minutes, 1 heure ou 24 heures ;
- **Processes** : rankings CPU, RAM et Disk avec PID, processus et métriques ;
- **Events** : événements récents, sévérité, type, message et valeur ;
- **Diagnostics** : état runtime, âge du statut, `fs_usage`, permission, dropped events, chemins et erreurs locales.

L'interface affiche l'âge des données (`Live`, `Updated Ns ago`, `Stale` ou
`No data`). Elle ne peut pas afficher `Live` quand le statut runtime est stale.
Les absences sont explicites et ne sont jamais remplacées par des zéros
artificiels. Si SQLite est absent ou incompatible, le Dashboard reste ouvert et
retente la lecture lors du prochain refresh.

## Arrêt

Dans le terminal qui lance Personal OS, utiliser `Ctrl+C` (`TERM` est aussi
géré). Le Dashboard et mac-detective sont alors arrêtés ; mac-detective
termine son graceful shutdown avant que le launcher ne rende la main.

## Validation

```sh
swift build --package-path apps/mac-detective
swift test --package-path apps/mac-detective
swift build --package-path apps/dashboard
swift test --package-path apps/dashboard
git diff --check
```

Les tests du launcher peuvent aussi être exécutés avec :

```sh
./scripts/test-personal-os-launcher.sh
```

Sur le smoke test local exécuté pendant M011, le Dashboard est resté autour de
0–17 % CPU et 93–103 MB RSS sur la machine de validation, tandis que
mac-detective est resté autour de 0–3 % CPU et 10–12 MB RSS avec `fs_usage`
désactivé. Ces valeurs sont indicatives et dépendent de la charge et du nombre
de processus ; elles ne remplacent pas une mesure sur la machine cible.

## Smoke test local

Procureure courte, sans privilèges :

1. lancer `./scripts/build-personal-os.sh` ;
2. lancer `./scripts/start-personal-os.sh` dans un terminal ;
3. laisser le runtime actif quelques minutes ;
4. vérifier que `system_samples`, `process_samples` et les agrégats évoluent ;
5. vérifier le statut JSON, les rankings CPU/RAM/Disk, les événements et les
   pages History/Diagnostics dans le Dashboard ;
6. fermer avec `Ctrl+C` et vérifier qu'il ne reste aucun processus
   `mac-detective` ou `PersonalOSDashboard`.

`fs_usage` est désactivé par défaut ; le Dashboard affiche alors `disabled`.
Si l'utilisateur l'active explicitement sans permission, il doit afficher
l'état `permission denied` et les événements disk restent absents ou limités.
Cela ne constitue pas un test root. Ne pas utiliser `sudo` automatiquement.

## Portée de M011

M011 ne fournit volontairement pas de `launchd`, de daemon système, de Life
API, de backend cloud, de ML, de notifications, de login ou de télémétrie.
`fs_usage` reste optionnel et son état de permission est affiché tel que fourni
par mac-detective ; aucun test root n'est simulé.
