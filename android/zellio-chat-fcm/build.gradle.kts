plugins {
    alias(libs.plugins.android.library)
    `maven-publish`
    signing
}

group = "ai.zellio"
version = "1.0.1"

android {
    namespace = "ai.zellio.chat.fcm"
    compileSdk = 36
    resourcePrefix = "zcf_"

    defaultConfig {
        minSdk = 24
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
}

kotlin {
    explicitApi()
    coreLibrariesVersion = libs.versions.kotlinHostFloor.get()
    compilerOptions {
        languageVersion = org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_2_2
        apiVersion = org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_2_2
    }
}

dependencies {
    api(project(":zellio-chat"))
    api(libs.firebase.messaging)
    implementation(libs.core.ktx)
    implementation(libs.lifecycle.process)
}

publishing {
    publications {
        register<MavenPublication>("release") {
            groupId = "ai.zellio"
            artifactId = "zellio-chat-fcm"
            version = project.version.toString()
            afterEvaluate { from(components["release"]) }
            pom {
                name.set("ZeeChat Android SDK: FCM")
                description.set("A ready FirebaseMessagingService that forwards ZeeChat pushes to the ZeeChat SDK.")
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

// Signing only runs when the key is passed in (CI). Nothing is published from a laptop.
if (project.hasProperty("signingInMemoryKey")) {
    signing {
        useInMemoryPgpKeys(
            project.property("signingInMemoryKey") as String,
            project.findProperty("signingInMemoryKeyPassword") as String?,
        )
        sign(publishing.publications)
    }
}
