package app.xingji.memo

import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.util.UUID

/** Private working copies from the Android document picker, shared across Flutter engines. */
internal object BackupImports {
    private val owners = mutableMapOf<File, String>()
    private val backupName = Regex("[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\\.xingji")

    @Synchronized
    fun create(folder: File, owner: String): File {
        folder.mkdirs()
        check(Files.isDirectory(folder.toPath(), LinkOption.NOFOLLOW_LINKS))
        val file = File(folder, "${UUID.randomUUID()}.xingji")
        check(file.createNewFile())
        owners[file] = owner
        return file
    }

    @Synchronized
    fun release(file: File, owner: String) {
        if (owners[file] != owner) return
        owners.remove(file)
        file.delete() // A failed deletion is retried by recover() on the next launch.
    }

    @Synchronized
    fun close(owner: String) {
        owners.filterValues { it == owner }.keys.forEach { release(it, owner) }
    }

    @Synchronized
    fun recover(folder: File) {
        if (!Files.isDirectory(folder.toPath(), LinkOption.NOFOLLOW_LINKS)) return
        folder.listFiles()?.forEach { file ->
            if (file !in owners && backupName.matches(file.name) &&
                Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS)) {
                file.delete()
            }
        }
    }
}
