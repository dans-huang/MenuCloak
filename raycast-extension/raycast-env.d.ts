/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `set-focus` command */
  export type SetFocus = ExtensionPreferences & {}
  /** Preferences accessible in the `toggle` command */
  export type Toggle = ExtensionPreferences & {}
  /** Preferences accessible in the `turn-on` command */
  export type TurnOn = ExtensionPreferences & {}
  /** Preferences accessible in the `turn-off` command */
  export type TurnOff = ExtensionPreferences & {}
  /** Preferences accessible in the `open-settings` command */
  export type OpenSettings = ExtensionPreferences & {}
}
declare namespace Arguments {
  /** Arguments passed to the `set-focus` command */
  export type SetFocus = {}
  /** Arguments passed to the `toggle` command */
  export type Toggle = {}
  /** Arguments passed to the `turn-on` command */
  export type TurnOn = {}
  /** Arguments passed to the `turn-off` command */
  export type TurnOff = {}
  /** Arguments passed to the `open-settings` command */
  export type OpenSettings = {}
}
