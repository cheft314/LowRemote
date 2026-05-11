package com.lowremote.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Shapes
import androidx.compose.ui.unit.dp

val AppShapes = Shapes(
    // Used for small chips, tags, key buttons
    extraSmall = RoundedCornerShape(6.dp),
    // Used for input fields, secondary buttons
    small      = RoundedCornerShape(10.dp),
    // Used for cards, list items, dialogs
    medium     = RoundedCornerShape(14.dp),
    // Used for bottom sheets, large cards
    large      = RoundedCornerShape(20.dp),
    // Used for FABs, pill buttons
    extraLarge = RoundedCornerShape(50.dp),
)
