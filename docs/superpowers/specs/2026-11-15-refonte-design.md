# Refonte complète de Dressly — design

Date : 2026-11-15 · Statut : en attente d'approbation

## Intention

L'app fonctionne, mais elle est moche, pas fluide et lente. On la refait presque entièrement, étape par étape. Elle doit avoir une vraie identité, coller à une garde-robe **streetwear**, et ne surtout pas ressembler à une app générée par IA. Côté code : tout est standardisé et la qualité est irréprochable.

## Objectifs

- Une identité visuelle forte et cohérente sur tous les écrans : la direction **F « Étiquette × Atelier »**.
- Fluidité : aucune saccade visible au défilement ni dans les transitions, mesurée sur le téléphone de l'utilisateur.
- Rapidité : démarrage, ouverture des écrans et chargement des images mesurés avant et après, et améliorés.
- Code standardisé : aucun écran ne définit ses propres couleurs, typos, arrondis ou durées. Tout passe par le système de design.
- Architecture prête pour **plusieurs thèmes** plus tard (Zine, Utilitaire…). Un thème change la typo, les formes, la densité et les animations, pas seulement les couleurs.

## Non-objectifs (pour cette refonte)

- Livrer les thèmes alternatifs. L'architecture les permet, mais on ne les construit pas maintenant.
- Modifier le backend ou l'API, sauf si la mesure de performance montre que le goulot est côté serveur. Dans ce cas, ce sera une étape séparée.
- Ajouter des fonctionnalités. On garde le périmètre fonctionnel actuel.

## Anti-objectifs (échec même si « ça marche »)

- Un look IA générique : dégradés violets, glassmorphism, icônes emoji, Material 3 par défaut à peine recoloré, cartes blanches à ombre douce.
- Perdre un comportement existant pendant la migration.
- Une app plus jolie mais plus lente.
- Un système de design contourné : des couleurs ou des `TextStyle` en dur qui réapparaissent dans les écrans.

## Contraintes

- Flutter, SDK `^3.12`, Android uniquement, un seul utilisateur.
- Langues FR et EN via `lib/l10n/app_text.dart`.
- Dépôt public : aucun secret dans le code ni dans la documentation.
- Les 24 fichiers de tests existants restent verts à chaque étape. Les pièges du banc de test de widgets sont décrits dans la mémoire du projet.
- Chaque étape laisse l'app utilisable.

## Approches envisagées

1. **Système de design d'abord, puis migration écran par écran dans l'app existante.** — *Retenue.* L'app reste utilisable en permanence, les tests existants protègent les comportements, et on mesure la performance écran par écran.
2. Nouvelle app en parallèle, puis bascule. — Écartée : rien d'utilisable avant la fin, et un fort risque de perdre des comportements, car les tests protègent l'ancienne app, pas la nouvelle.
3. Simple changement de thème. — Écartée : ne règle ni la qualité du code ni la lenteur.

## Direction visuelle (décidée)

Base **F** (sombre et chaud, street). On y ajoute deux emprunts :

- **Écran Tenue : affichage en couches, repris de E.** Ordre : L3 extérieur, L2 milieu, bas, pieds. Météo du jour affichée (température, pluie, nombre de couches). Cela s'appuie sur `models/layering.dart` et `models/weather.dart`, qui existent déjà.
- **Moment « tenue générée » : collage, repris de D.** Les pièces arrivent de biais comme des stickers, puis se remettent en place. C'est le seul moment « fun » de l'app.

Référence des maquettes : `.superpowers/brainstorm/…/directions-v2.html` (section F), non versionnée.

### Langage visuel F

- **Couleurs (sombre)** : fond `#17120F` (noir chocolat), surface `#2A221C`, texte `#F1E6D6` (crème), texte secondaire `#8D7C6B`, accent `#FF7A3D` (orange vif), olive `#56603D` en couleur secondaire.
- **Typo** : titres en **Anton** (condensée, capitales, très grande), texte courant en **Bricolage Grotesque**, métadonnées en **IBM Plex Mono** (comptes, dates, températures, en capitales). Les polices sont embarquées comme assets, sans téléchargement au runtime.
- **Formes** : cartes très arrondies (20–26 px), pilules pour les puces, les boutons et la barre de navigation flottante.
- **Cartes vêtement** : la photo détourée (`cutoutUrl`) est posée sur un fond tiré de la couleur principale du vêtement (`colors`), avec une teinte assombrie pour la silhouette, comme un échantillon de tissu. Les badges en mono (TOP, DORT…) remplacent les anciens badges.
- **En-têtes d'écran** : titre géant sur deux lignes, le second mot en accent (« MA / DRIP », « FIT DU / JOUR »), avec un bloc mono aligné à droite (compte, date, météo).
- **Animations** : ressorts souples sur les cartes (léger soulèvement à l'appui), transitions d'écran rapides (moins de 250 ms), aucun rebond mou dans les listes.

## Architecture (décidée)

### Système de design — `lib/design/`

- **Jetons** sous forme de `ThemeExtension` immuables : `DsColors`, `DsType`, `DsShape` (arrondis), `DsSpace` (espacements), `DsMotion` (durées et courbes), `DsDensity`. Un thème Dressly est un `DsTheme` qui regroupe tous ces jetons. Changer de thème revient à fournir un autre `DsTheme`.
- **Composants** préfixés `Ds…`, qui lisent uniquement les jetons : `DsScaffold`, `DsHeader`, `DsTabBar` (pilule flottante), `DsChip`/`DsSegment`, `DsButton` (primaire, secondaire, icône), `DsSwatchCard` (vêtement), `DsBadge`, `DsSheet`, `DsDayStrip`, `DsPlanCard`, `DsLayerRow`, `DsCollage`, ainsi que les états `DsEmpty`, `DsError` et `DsSkeleton`.
- Une **galerie** des composants (écran de debug, absent en release) avec des tests golden par composant, en sombre et en clair.
- **Garde-fou** : un test échoue si un fichier hors de `lib/design/` contient `Color(0x`, `Colors.` (sauf `Colors.transparent`), `TextStyle(`, `BorderRadius.circular(<nombre>)` ou une `Duration(` d'animation en dur.

### État

- **Riverpod** remplace Provider. Les contrôleurs `session`, `theme`, `locale` et `gen_prefs` sont portés en premier, puis l'état de chaque écran au moment de sa migration. Les `setState` restent uniquement pour l'état purement local et visuel (focus, animation).
- Les services (`lib/services/`) et les modèles (`lib/models/`) sont conservés et seulement adaptés si nécessaire. Ils sont exposés via des providers.

### Performance

- **Étape 0 obligatoire** : mesure de référence en mode profile sur le téléphone. Temps de frame au défilement de la garde-robe, démarrage à froid, ouverture du détail, génération d'une tenue, temps des appels API. Aucune optimisation n'est choisie avant cette mesure.
- Chaque écran migré est re-mesuré, et la comparaison est notée dans le message de commit.

## Ordre des étapes

0. Mesure de référence.
1. Fondations : jetons, polices, thème F sombre et clair, garde-fou.
2. Composants et galerie, avec leurs tests golden.
3. Passage à Riverpod (racine et contrôleurs globaux).
4. Écrans, dans cet ordre : navigation principale, garde-robe, détail vêtement, ajout et retouche photo, Tenue (création, algo, résultat avec collage, constructeur manuel), agenda et semaine, favoris, profil et réglages, modèles, connexion et inscription, vêtements dormants.
5. Nettoyage : suppression de l'ancien code (`theme/tones.dart`, sélecteur de couleur obsolète, widgets remplacés).

Chaque étape est un ou plusieurs commits, avec les tests verts et l'app installée et vérifiée sur le téléphone.

## Choix faits par l'assistant (à vérifier)

- **Mode clair conservé** en variante de F : fond crème `#F1E6D6`, texte chocolat, même accent. L'utilisateur garde le choix clair/sombre/système. Le sombre reste par défaut.
- **Sélecteur d'accent** réduit à 5 accents qui vont avec F (orange par défaut, olive, rouge brique, bleu encre, jaune acide). Les 10 couleurs Material actuelles disparaissent.
- **5 onglets conservés** (garde-robe, créer, agenda, sauvés, profil), avec des libellés plus street : Stock, Fit, Semaine, Sauvés, Moi.
- **Riverpod** plutôt que de rester sur Provider : meilleure testabilité, reconstructions ciblées.

## Laissé au constructeur

- Le détail des jetons d'espacement et de durée, dans l'esprit des maquettes.
- Le découpage des gros écrans (> 500 lignes) en sous-widgets.
- Le choix du générateur de code Riverpod (avec ou sans annotations).
