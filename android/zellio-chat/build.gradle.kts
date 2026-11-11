import groovy.json.JsonSlurper
import java.util.zip.ZipFile

plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    `maven-publish`
    signing
}

group = "ai.zellio"
version = "1.0.1"

android {
    namespace = "ai.zellio.chat"
    compileSdk = 36
    resourcePrefix = "zc_"

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
        buildConfigField("String", "SDK_VERSION", "\"${project.version}\"")
    }
    buildFeatures {
        buildConfig = true
        compose = true
    }
    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    publishing {
        singleVariant("release") {
            withSourcesJar()
            withJavadocJar()
        }
    }
    testOptions {
        unitTests.all {
            it.systemProperty("zellio.contract.dir", rootDir.resolve("../contract/v1").canonicalPath)
            it.systemProperty("zellio.design.dir", rootDir.resolve("../design").canonicalPath)
            it.systemProperty("zellio.module.dir", projectDir.canonicalPath)
        }
    }
}

kotlin {
    explicitApi()
    // A host on Kotlin 2.2 must be able to read this library: write 2.2 metadata and depend on the 2.2 stdlib.
    coreLibrariesVersion = libs.versions.kotlinHostFloor.get()
    compilerOptions {
        languageVersion = org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_2_2
        apiVersion = org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_2_2
        freeCompilerArgs.addAll("-Xjvm-default=all")
    }
}

dependencies {
    api(platform(libs.compose.bom))
    // Public API types: Modifier (ZellioChatScreen), ComponentActivity (ZellioChatActivity), StateFlow/SharedFlow.
    api(libs.compose.ui)
    implementation(libs.compose.foundation)
    api(libs.activity.compose)
    implementation(libs.core.ktx)
    implementation(libs.lifecycle.process)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    api(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.serialization.json)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}

// ---- strings: design/strings.json is the only source; res/values and res/values-ar are generated ----

val stringsJson = rootDir.resolve("../design/strings.json")

fun resourceName(key: String): String =
    "zc_" + key.replace('.', '_').replace(Regex("([a-z0-9])([A-Z])"), "$1_$2").lowercase()

fun xmlEscape(value: String): String {
    val sb = StringBuilder()
    value.forEachIndexed { i, ch ->
        when (ch) {
            '&' -> sb.append("&amp;")
            '<' -> sb.append("&lt;")
            '>' -> sb.append("&gt;")
            '\'' -> sb.append("\\'")
            '"' -> sb.append("\\\"")
            '\n' -> sb.append("\\n")
            '@', '?' -> if (i == 0) sb.append('\\').append(ch) else sb.append(ch)
            else -> sb.append(ch)
        }
    }
    return sb.toString()
}

val generateStrings = tasks.register("generateStrings") {
    group = "zellio"
    description = "Generates res/values/strings.xml and res/values-ar/strings.xml from sdks/design/strings.json."
    inputs.file(stringsJson)
    val enOut = layout.projectDirectory.file("src/main/res/values/zc_strings.xml")
    val arOut = layout.projectDirectory.file("src/main/res/values-ar/zc_strings.xml")
    outputs.files(enOut, arOut)
    doLast {
        @Suppress("UNCHECKED_CAST")
        val all = JsonSlurper().parse(stringsJson) as Map<String, Map<String, String>>
        fun write(locale: String, target: File) {
            val map = all.getValue(locale)
            val body = map.entries.joinToString("\n") { (k, v) ->
                "    <string name=\"${resourceName(k)}\">${xmlEscape(v)}</string>"
            }
            target.parentFile.mkdirs()
            target.writeText(
                "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
                    "<!-- Generated from sdks/design/strings.json by :zellio-chat:generateStrings. Do not edit. -->\n" +
                    "<resources>\n$body\n</resources>\n",
            )
        }
        write("en", enOut.asFile)
        write("ar", arOut.asFile)
    }
}

tasks.matching { it.name == "preBuild" }.configureEach { dependsOn(generateStrings) }

// ---- size budget: the AAR must stay under 2 MB and carry no native libraries ----

val sizeBudgetBytes = 2L * 1024 * 1024

val checkSdkSize = tasks.register("checkSdkSize") {
    group = "verification"
    description = "Fails when the release AAR is over the 2 MB budget or contains a .so file."
    val aar = layout.buildDirectory.file("outputs/aar/zellio-chat-release.aar")
    doLast {
        val file = aar.get().asFile
        check(file.exists()) { "Release AAR not found: $file. Run :zellio-chat:assembleRelease first." }
        val size = file.length()
        ZipFile(file).use { zip ->
            val natives = zip.entries().asSequence().map { it.name }.filter { it.endsWith(".so") }.toList()
            check(natives.isEmpty()) { "Native libraries are not allowed: $natives" }
        }
        println("zellio-chat release AAR: $size bytes (budget $sizeBudgetBytes)")
        check(size <= sizeBudgetBytes) { "AAR is $size bytes, over the budget of $sizeBudgetBytes bytes." }
    }
}

tasks.matching { it.name == "assembleRelease" }.configureEach { finalizedBy(checkSdkSize) }
tasks.matching { it.name == "check" }.configureEach { dependsOn(checkSdkSize) }

// ---- publishing: configured, never run here. Credentials come from Gradle properties. ----

afterEvaluate {
    publishing {
        publications {
            create<MavenPublication>("release") {
                from(components["release"])
                groupId = "ai.zellio"
                artifactId = "zellio-chat"
                version = project.version.toString()
                pom {
                    name.set("ZeeChat Android SDK")
                    description.set("Native Android chat SDK for Zellio ZeeChat.")
                    url.set("https://zellio.ai")
                    licenses { license { name.set("Apache-2.0"); url.set("https://www.apache.org/licenses/LICENSE-2.0.txt") } }
                    developers { developer { id.set("zellio"); name.set("Zellio"); email.set("support@zellio.ai") } }
                    scm {
                        url.set("https://github.com/zellio-ai/zellio-chat-sdk")
                        connection.set("scm:git:https://github.com/zellio-ai/zellio-chat-sdk.git")
                        developerConnection.set("scm:git:https://github.com/zellio-ai/zellio-chat-sdk.git")
                    }
                }
            }
        }
    }
    signing {
        val key = providers.gradleProperty("signingInMemoryKey").orNull
        val password = providers.gradleProperty("signingInMemoryKeyPassword").orNull
        isRequired = false
        if (key != null) {
            useInMemoryPgpKeys(key, password)
            sign(publishing.publications)
        }
    }
}
