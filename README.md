# DezHelper

DezHelper is a lightweight disenchanting queue for World of Warcraft Retail.
It scans your bags, lets you filter equipment by rarity, and prepares the next
selected item for disenchanting.

## Features

- Compact and movable window
- Uncommon, Rare, and Epic quality filters
- Item level and upgrade track progress
- Automatic filtering of refundable and known non-disenchantable items
- Individual checkboxes and Select All
- Adjustable interface scale
- English and French interface
- Safe one-click-per-item workflow
- Automatic refresh when bags change

## Usage

Type `/dez` or `/dezhelper` to open the window.

Type `/dez reset` to clear the learned non-disenchantable item list.

1. Choose the rarities to display.
2. Select the items you want to process.
3. Click **Disenchant next item** once per item.

World of Warcraft requires a separate hardware action for each disenchant.
DezHelper never automates multiple disenchants from a single click.

## Compatibility

- World of Warcraft Retail 12.0.7+
- English clients (`enUS`, `enGB`)
- French clients (`frFR`)

## Installation

Copy the `DezHelper` folder into:

`World of Warcraft/_retail_/Interface/AddOns/`

Restart the game or type `/reload`.

## Feedback

Please report bugs through the GitHub issue tracker associated with the
project.
