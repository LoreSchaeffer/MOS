#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <ctype.h>

typedef uint8_t boolean;
#define true 1
#define false 0

typedef struct {
  uint8_t BootJumpInstructions[3];
  uint8_t OemIdentifier[8];
  uint16_t BytesPerSector;
  uint8_t SectorsPerCluster;
  uint16_t ReservedSectors;
  uint8_t FatCount;
  uint16_t DirectoryEntriesCount;
  uint16_t TotalSectors;
  uint8_t MediaDescriptorType;
  uint16_t SectorsPerFat;
  uint16_t SectorsPerTrack;
  uint16_t Heads;
  uint32_t HiddenSectors;
  uint32_t LargeSectorCount;

  // Extended boot record
  uint8_t DriveNumber;
  uint8_t _Reserved;
  uint8_t Signature;
  uint32_t VolumeId;
  uint8_t VolumeLabel[11];
  uint8_t SystemId[8];
} __attribute__((packed)) BootSector;

typedef struct {
  uint8_t Name[11];
  uint8_t Attributes;
  uint8_t _Reserved;
  uint8_t CreatedTimeTenths;
  uint16_t CreatedTime;
  uint16_t CreatedDate;
  uint16_t AccessedDate;
  uint16_t FirstClusterHigh;
  uint16_t ModifiedTime;
  uint16_t ModifiedDate;
  uint16_t FirstClusterLow;
  uint32_t Size;
} __attribute__((packed)) DirectoryEntry;

BootSector gBootSector;
uint8_t *gFat = NULL;
DirectoryEntry *gRootDirectory = NULL;
uint32_t gRootDirectoryEnd;

boolean readBootSector(FILE *disk) {
  return fread(&gBootSector, sizeof(BootSector), 1, disk) > 0;
}

boolean readSectors(FILE *disk, uint32_t lba, uint32_t count, void *outBuffer) {
  boolean ok = true;
  ok = ok && (fseek(disk, lba * gBootSector.BytesPerSector, SEEK_SET) == 0);
  ok = ok && (fread(outBuffer, gBootSector.BytesPerSector, count, disk) == count);

  return ok;
}

boolean readFat(FILE *disk) {
  gFat =
      (uint8_t *)malloc(gBootSector.SectorsPerFat * gBootSector.BytesPerSector);
  return readSectors(disk, gBootSector.ReservedSectors,
                     gBootSector.SectorsPerFat, gFat);
}

boolean readRootDirectory(FILE *disk) {
  uint32_t lba = gBootSector.ReservedSectors + gBootSector.FatCount * gBootSector.SectorsPerFat;
  uint32_t size = sizeof(DirectoryEntry) * gBootSector.DirectoryEntriesCount;
  uint32_t sectors = (size / gBootSector.BytesPerSector);
  if (size % gBootSector.BytesPerSector > 0) sectors++;

  gRootDirectoryEnd = lba + sectors;
  gRootDirectory = (DirectoryEntry *) malloc(sectors * gBootSector.BytesPerSector);
  return readSectors(disk, lba, sectors, gRootDirectory);
}

DirectoryEntry* findFile(const char* name) {
  for (uint32_t i = 0; i < gBootSector.DirectoryEntriesCount; i++) {
    if (memcmp(name, gRootDirectory[i].Name, 11) == 0) return &gRootDirectory[i];
  }

  return NULL;
}

boolean readFile(DirectoryEntry* fileEntry, FILE* disk, uint8_t* outBuffer) {
  boolean ok = true;
  uint16_t currentCluster = fileEntry->FirstClusterLow;

  do {
    uint32_t lba = gRootDirectoryEnd + (currentCluster - 2) * gBootSector.SectorsPerCluster;
    ok = ok && readSectors(disk, lba, gBootSector.SectorsPerCluster, outBuffer);
    outBuffer += gBootSector.SectorsPerCluster * gBootSector.BytesPerSector;

    uint32_t fatIndex = currentCluster * 3 / 2;
    if (currentCluster % 2 == 0) currentCluster = (*(uint16_t*) (gFat + fatIndex)) & 0xFFF;
    else currentCluster = (*(uint16_t*) (gFat + fatIndex)) >> 4;
  } while(ok && currentCluster < 0xFF8);

  return ok;
}

int main(int argc, char **argv) {
  if (argc < 3) {
    printf("Syntax: %s <disk image> <file name>\n", argv[0]);
    return -1;
  }

  FILE *disk = fopen(argv[1], "rb");
  if (!disk) {
    fprintf(stderr, "Cannot open disk image %s!\n", argv[1]);
    return -1;
  }

  if (!readBootSector(disk)) {
    fprintf(stderr, "Cannot read boot sector!\n");
    return -2;
  }

  if (!readFat(disk)) {
    fprintf(stderr, "Cannot read FAT!\n");
    free(gFat);
    return -3;
  }

  if (!readRootDirectory(disk)) {
    fprintf(stderr, "Cannot read root directory!\n");
    free(gFat);
    free(gRootDirectory);
    return -4;
  }

  DirectoryEntry* fileEntry = findFile(argv[2]);
  if (!fileEntry) {
    fprintf(stderr, "Cannot find file %s!\n", argv[2]);
    free(gFat);
    free(gRootDirectory);
    return -5;
  }

  uint8_t* buffer = (uint8_t*) malloc(fileEntry->Size + gBootSector.BytesPerSector);
  if (!readFile(fileEntry, disk, buffer)) {
    fprintf(stderr, "Cannot read file %s!\n", argv[2]);
    free(gFat);
    free(gRootDirectory);
    free(buffer);
    return -6;
  }

  for (size_t i = 0; i < fileEntry->Size; i++) {
    if (isprint(buffer[i])) fputc(buffer[i], stdout);
    else printf("<%02x>", buffer[i]);
  }
  printf("\n");

  free(gFat);
  free(gRootDirectory);
  free(buffer);
  return 0;
}