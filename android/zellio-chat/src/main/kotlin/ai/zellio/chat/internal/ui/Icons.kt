package ai.zellio.chat.internal.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

private fun circle(cx: Float, cy: Float, r: Float): String =
    "M${cx - r},$cy a$r,$r 0 1,0 ${2 * r},0 a$r,$r 0 1,0 ${-2 * r},0"

private fun stroke(vararg paths: String): ImageVector {
    val b = ImageVector.Builder(
        defaultWidth = 24.dp,
        defaultHeight = 24.dp,
        viewportWidth = 24f,
        viewportHeight = 24f,
    )
    for (d in paths) {
        b.addPath(
            pathData = PathParser().parsePathString(d).toNodes(),
            fill = null,
            stroke = SolidColor(Color.Black),
            strokeLineWidth = 1.9f,
            strokeLineCap = StrokeCap.Round,
            strokeLineJoin = StrokeJoin.Round,
        )
    }
    return b.build()
}

/** Line icons, 24 x 24, 1.9 stroke, round caps: the same set as the design canvas. */
internal object Icons {
    val back by lazy { stroke("m15 18-6-6 6-6") }
    val forward by lazy { stroke("m9 6 6 6-6 6") }
    val close by lazy { stroke("M18 6 6 18M6 6l12 12") }
    val send by lazy { stroke("M12 19V5", "m6 11 6-6 6 6") }
    val clip by lazy {
        stroke("m21 11.5-8.6 8.6a5.5 5.5 0 0 1-7.8-7.8l8.8-8.8a3.7 3.7 0 0 1 5.2 5.2l-8.8 8.8a1.8 1.8 0 0 1-2.6-2.6l8.1-8.1")
    }
    val chat by lazy { stroke("M21 12a8.5 8.5 0 0 1-12.6 7.4L3 21l1.6-5.4A8.5 8.5 0 1 1 21 12Z") }
    val link by lazy {
        stroke("M14 5h5v5", "M19 5 10 14", "M18 14v4a1.5 1.5 0 0 1-1.5 1.5h-10A1.5 1.5 0 0 1 5 18V8a1.5 1.5 0 0 1 1.5-1.5H10")
    }
    val clock by lazy { stroke(circle(12f, 12f, 8.5f), "M12 7.5V12l3 2") }
    val alert by lazy { stroke(circle(12f, 12f, 8.5f), "M12 8v5", "M12 16.3v.2") }
    val camera by lazy {
        stroke(
            "M4 8.5A1.5 1.5 0 0 1 5.5 7h2.3l1.4-2h5.6l1.4 2h2.3A1.5 1.5 0 0 1 20 8.5v9a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 17.5Z",
            circle(12f, 13f, 3.4f),
        )
    }
    val image by lazy {
        stroke(
            "M6.5 5h11A2.5 2.5 0 0 1 20 7.5v9a2.5 2.5 0 0 1-2.5 2.5h-11A2.5 2.5 0 0 1 4 16.5v-9A2.5 2.5 0 0 1 6.5 5Z",
            circle(9f, 10f, 1.5f),
            "m5 17 4.5-4 3.5 3 2.5-2 3.5 3",
        )
    }
    val file by lazy { stroke("M14 3.5H7.5A1.5 1.5 0 0 0 6 5v14a1.5 1.5 0 0 0 1.5 1.5h9A1.5 1.5 0 0 0 18 19V7.5Z", "M14 3.5V7.5h4") }
    val plus by lazy { stroke("M12 5v14M5 12h14") }
    val wifi by lazy { stroke("M4 9.5a12 12 0 0 1 16 0", "M7.5 13a7 7 0 0 1 9 0", "M12 17.5v.1") }
    val headset by lazy {
        stroke(
            "M5 13.5v-1.5a7 7 0 0 1 14 0v1.5",
            "M5 13h2v5.5H5a1.5 1.5 0 0 1-1.5-1.5v-2.5A1.5 1.5 0 0 1 5 13Z",
            "M19 13h-2v5.5h2a1.5 1.5 0 0 0 1.5-1.5v-2.5A1.5 1.5 0 0 0 19 13Z",
        )
    }
    val lock by lazy { stroke("M7 11V8a5 5 0 0 1 10 0v3", "M6.5 11h11A1.5 1.5 0 0 1 19 12.5v6a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 5 18.5v-6A1.5 1.5 0 0 1 6.5 11Z") }
}

/** A line icon. `mirror` flips it in right-to-left layouts (arrows, send). */
@Composable
internal fun Icon(
    vector: ImageVector,
    tint: Color,
    size: Dp = 22.dp,
    mirror: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val flip = mirror && chatEnv.rtl
    Image(
        imageVector = vector,
        contentDescription = null,
        colorFilter = ColorFilter.tint(tint),
        modifier = modifier.size(size).then(if (flip) Modifier.scale(scaleX = -1f, scaleY = 1f) else Modifier),
    )
}
