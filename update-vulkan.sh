#!/bin/sh
cd "./dependencies/vk"
curl -Lo vk.xml https://raw.githubusercontent.com/KhronosGroup/Vulkan-Docs/main/xml/vk.xml
vulkan-zig-generator vk.xml vk.zig