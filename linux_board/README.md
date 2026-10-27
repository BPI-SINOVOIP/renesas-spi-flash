Select the target bootloader directory, then pass the same target to the
partition flashing script:

```sh
source ../env.sh ai2h
./spi_flash_partition.sh ai2h

source ../env.sh ai2n
./spi_flash_partition.sh ai2n

source ../env.sh g3l
./spi_flash_partition.sh g3l
```

By default, the script erases only the `bl2` and `fip` partitions. Use the
optional flags when the environment or user-data partitions must also be
erased:

```sh
./spi_flash_partition.sh ai2h --erase-env
./spi_flash_partition.sh ai2n --erase-user
./spi_flash_partition.sh g3l --erase-env --erase-user
```
